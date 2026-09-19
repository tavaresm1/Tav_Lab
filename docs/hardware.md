# tav-serv hardware inventory

Hardware snapshot as of 2026-07-05; OS section updated for the Proxmox rebuild.
See also: [../ansible/inventory/host_vars/tav-serv.yml](../ansible/inventory/host_vars/tav-serv.yml).

## OS

- **Proxmox VE 9.2.2**, kernel `7.0.2-6-pve` (Debian 13 trixie base) — `pveversion`, 2026-09-18
- **Hostname / PVE node name: `pve`.** "tav-serv" is what we call the machine and
  the alias the Ansible inventory uses; the node itself is `pve`. `pve_node` in
  `inventory/group_vars/autobase.yml` must say `pve`.
- Previously Linux Mint 22.3 + VirtualBox; that era's software inventory is kept
  at [context/tav-serv-inventory.md](context/tav-serv-inventory.md) as history
- Administered as `root`; Ansible connects with the `ansible_control` key
- Partitioning and swap are the PVE installer's, not Ansible's

## Chassis

- Dell PowerEdge R610
- BIOS 6.4.0 (2013-07-23) — final for the platform is 6.6.0 (Feb 2018)
- iDRAC6 firmware 2.85, shared LOM mode. **Address unconfirmed:** the 2026-07-05
  audit recorded `192.168.0.120`, but the LAN is `192.168.1.0/24` (tav-serv is
  `192.168.1.226`), so that cannot be right as written. Run `ipmitool lan print 1`
  on the host and correct this line.
- Enterprise iDRAC card physically present per BMC sensor; license status TBD

## CPU

- Socket 1: 1× Intel Xeon **X5670** (6c/12t, Westmere-EP, LGA 1366, 95W)
- Socket 2: **empty** — matching X5670 (SLBV7) ordered, heatsink PN GY611 pending
- **Microarchitecture level: `x86-64-v2`.** Westmere-EP (2010) has SSE4.2 but no
  AVX, AVX2, BMI2 or FMA. This is a hard constraint on guest OS choice, not a
  tunable: anything requiring `x86-64-v3` (RHEL 10 and its rebuilds, including
  Rocky 10) will not boot here regardless of the VM's `--cpu` type, and fails
  before reaching a console. The second CPU does not change this.

## Memory

**40,188 MB total** (`free -m`, 2026-09-18) — *not* the 24 GB recorded at the
2026-07-05 audit. DIMMs were added and never written down; the population is
unknown and `dmidecode -t memory` is the way to find out. 40 GB is an odd total
for a triple-channel Westmere box (10× 4 GB), so the channel layout may be
suboptimal — worth checking before buying more.

- Was: 24 GB in CPU1 bank (6× 4 GB Kingston `9965433-034.A00LF`, DDR3-1333 ECC RDIMM 1Rx4)
- CPU2 bank status now unknown — 8× Hynix `HMT351R7BFR4C-H9` (4GB 1Rx4 PC3-10600R)
  were ordered; some or all may already be installed

Guest memory was trimmed on 2026-09-18 to make room for the Autobase platform.
Configured totals after the trim:

| VMID | Guest | Configured | |
|---|---|---|---|
| 100 | `NAS` | 8048 MB | running |
| 101 | `Kieran-Craft` | 8000 MB | was 16000 |
| 102 | `Tav-Assistant` | 4080 MB | was 8048 |
| 103 | `Hermes` | 4048 MB | was 18000 |
| 104 | `KCraft-b` | 1024 MB | was 8048 |
| | **existing total** | **25,200 MB** | |
| 8001-8003, 8010 | Autobase platform | 9,728 MB | balloon off on the DB nodes |
| | **committed if everything runs** | **34,928 MB** | of 40,188 MB |

That leaves ~5.2 GB for PVE itself plus the ZFS ARC, which is workable but has no
slack. When the measurement was taken only VM 100 was running, which is why
`free -m` showed 25,669 MB available; the 34,928 MB figure is the all-guests-running
case and is the one to plan against. Three things follow:

- **The 8 GB `zfs_arc_max` cap is too generous until the RAM upgrade lands** —
  34,928 + 8,192 exceeds physical RAM. The ARC's real working set is 3.7 GB, so
  4 GB (`zfs_arc_max=4294967296`) is the right interim ceiling if everything is
  going to run at once.
- **The DB nodes set `balloon: 0` and the pre-existing guests set no `balloon` key
  at all** (verified 2026-09-18), so PVE can reclaim from all five of them but not
  from the DB nodes. That is the right priority ordering: under pressure Minecraft
  yields pages, `shared_buffers` does not. The 8 GB swap partition is the backstop
  and is currently untouched.
- **A 96 GB upgrade is planned** (stated 2026-09-18), after which none of this is
  tight: 34,928 MB against 96 GB is comfortable, the 8 GB ARC cap becomes sensible
  rather than greedy, and the trimmed guests can have their memory back. Note that
  a single X5670 only lights 9 of the R610's 18 DIMM slots — see
  [context/upgrades-in-flight.md](context/upgrades-in-flight.md).

The ZFS ARC was the obvious suspect for the original shortfall and was **not** the
cause — measured at 3.7 GB against a ~20 GB default ceiling. The RAM was genuinely
in the guests. Don't go looking there again.

## Storage

Re-audited 2026-09-18 (`lsblk`, `zpool status`, `smartctl --scan`, `pvesm status`).
**17 devices, all SSD except the PERC volume's members.** The 2026-07-05 record of
"RAID 0 across 2× 1 TB Seagate HDDs" is long gone.

| Store | Type | Total | Free | Backed by |
|---|---|---|---|---|
| `local` | dir | 94 GB | 64 GB | `pve-root` on the PERC volume — ISOs, templates, image cache |
| `local-lvm` | lvmthin | 976 GB | 844 GB | `pve-data` thin pool on the PERC volume. **`pve_storage` points here** |
| `Big_Data1` | zfspool | 4.8 TB | 1.8 TB | 8× Intel S3510 800 GB, raidz1 |
| `Big_Data2` | zfspool | 3.6 TB | 3.6 TB | 8× Intel S3500 600 GB, raidz1. Empty |

### PERC H700 volume (`/dev/sda`, 1.1 TB)

- **Four** physical members, `megaraid,0` through `megaraid,3` — the earlier
  record of two is wrong, and `host_vars/tav-serv.yml` had only `[0, 1]`.
- 1.1 TiB usable from four members implies RAID 5 (3+1) or 3 members plus a hot
  spare. Confirm with `perccli /c0 show` or `megacli -LDInfo -Lall -a0`.
- Carries the whole PVE install: `pve-swap` 8 GB, `pve-root` 96 GB,
  `pve-data` thin pool 976 GB. Guest disks for VMs 100, 102 and 103 live here,
  which is where the Autobase guests will land too.

### ZFS pools (SATA SSDs, not behind the PERC)

- `Big_Data1` — raidz1 across 8× `INTEL SSDSC2BB800G6` (S3510 800 GB).
  Scrubbed clean 2026-09-13 (0 errors, 1h29m).
- `Big_Data2` — raidz1 across 8× `INTEL SSDSC2BB600G4` (S3500 600 GB).
  ONLINE, no errors, currently empty.
- Both pools are ONLINE with no known data errors. Members are referenced by
  `ata-INTEL_*_<serial>` paths, so they survive `sdX` renumbering.
- **Neither pool is this repo's concern**, but their ARC competes with guest RAM
  — see the Memory section.

The 3× `SSDSC2BX800G4R` in [context/upgrades-in-flight.md](context/upgrades-in-flight.md)
are moot: the box already runs 16 enterprise SSDs.

## Networking

Confirmed 2026-09-18 with `ip -br addr` and `ip route show default`:

- 4× Broadcom BCM5709 gigabit, named **`nic0`-`nic3`**, not the `eno1`-`eno4`
  the earlier audit recorded. Only `nic1` is UP, enslaved to PVE's `vmbr0`.
  (Non-default names mean a `systemd.link` file or a kernel `net.ifnames`
  setting is in play — worth knowing before touching `/etc/network/interfaces`.)
- `vmbr0` holds `192.168.1.226/24`; default route via `192.168.1.1`.
  `pve_bridge: vmbr0` in `inventory/group_vars/autobase.yml` matches.
- `.226` is **static** (confirmed 2026-09-18), so the inventory is safe to reach
  the box by address — `ansible_host=192.168.1.226` in `inventory/hosts.ini`.
- iDRAC address unconfirmed — see the Chassis section.
- `tailscale0` is up at `100.111.136.81`. **MagicDNS name is `pve`, not
  `tav-serv`** — the node is named after the hostname. Prefer the LAN address or
  `pve`; a tailnet IP written down anywhere is a bug waiting to happen.

## Virtualization capabilities

- VT-x present (`vmx` flag)
- VT-d / IOMMU enabled + interrupt remapping active — PVE can do PCIe
  passthrough, though nothing in this repo uses it
- Notable IOMMU groups:
  - Group 13: `01:00.0`/`.1` — first two BCM5709 NICs
  - Group 14: `02:00.0`/`.1` — second two BCM5709 NICs
  - Group 9: `03:00.0` PERC H700 (+ root port)

## Power / thermal

- Ambient 28°C, planar readings healthy
- Power restore policy: always-on

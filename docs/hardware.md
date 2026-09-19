# tav-serv hardware inventory

Hardware snapshot as of 2026-07-05; OS section updated for the Proxmox rebuild.
See also: [../ansible/host_vars/tav-serv.yml](../ansible/host_vars/tav-serv.yml).

## OS

- **Proxmox VE 9.2.2**, kernel `7.0.2-6-pve` (Debian 13 trixie base) — `pveversion`, 2026-09-18
- **Hostname / PVE node name: `pve`.** "tav-serv" is what we call the machine and
  the alias the Ansible inventory uses; the node itself is `pve`. `pve_node` in
  `group_vars/autobase.yml` must say `pve`.
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

- 24 GB in CPU1 bank (6× 4 GB Kingston `9965433-034.A00LF`, DDR3-1333 ECC RDIMM 1Rx4)
- CPU2 bank empty — 8× Hynix `HMT351R7BFR4C-H9` (4GB 1Rx4 PC3-10600R) ordered

> **Unverified against reality.** `qm list` on 2026-09-18 shows four *running*
> guests configured for 50,096 MB total (8048 + 16000 + 8048 + 18000). That is
> impossible on 24 GB unless the CPU2 bank went in without being recorded here, or
> PVE is running a ~2× ballooning overcommit. Settle it with `free -m` and
> `qm config <vmid> | grep -E '^(balloon|memory)'` before sizing anything new —
> the Autobase guests want another 9728 MB and three of them deliberately disable
> ballooning.

## Storage

> **This section is stale and the discrepancy is large.** `pvesm status` on
> 2026-09-18 reports ~9.3 TB across four stores, which two 1 TB drives cannot
> physically provide. Drives were clearly added at or after the Proxmox rebuild
> and never recorded here. Re-audit with `lsblk -o NAME,SIZE,MODEL,SERIAL`,
> `zpool status`, and `perccli /c0 show` (or `megacli -PDList -a0`).

Observed 2026-09-18:

| Store | Type | Total | Free | Notes |
|---|---|---|---|---|
| `local-lvm` | lvmthin | 976 GB | 844 GB | Default guest store. `pve_storage` points here. |
| `local` | dir | 94 GB | 64 GB | ISOs, templates, the cloud image cache |
| `Big_Data1` | zfspool | 4.8 TB | 1.8 TB | 64% used — not this repo's |
| `Big_Data2` | zfspool | 3.6 TB | 3.6 TB | Empty |

- PERC H700 hardware RAID controller
- **Previously (2026-07-05):** RAID 0 across 2× Seagate `ST91000640NS`
  (1 TB 2.5" SAS 7200 rpm), a deliberate no-redundancy scratch config.
  SMART clean at the time: Reallocated=1 baseline, no pending/uncorrectable,
  ~6100 PoH, temps 34-35°C. Which of the stores above this backs is unknown;
  the two ZFS pools are certainly not on it.
- **Pending:** 3× Intel `SSDSC2BX800G4R` (S3610 800 GB, Dell firmware, DWPD 3)
  - Offer submitted @ $85/3, contingent on SMART reports

## Networking

Confirmed 2026-09-18 with `ip -br addr` and `ip route show default`:

- 4× Broadcom BCM5709 gigabit, named **`nic0`-`nic3`**, not the `eno1`-`eno4`
  the earlier audit recorded. Only `nic1` is UP, enslaved to PVE's `vmbr0`.
  (Non-default names mean a `systemd.link` file or a kernel `net.ifnames`
  setting is in play — worth knowing before touching `/etc/network/interfaces`.)
- `vmbr0` holds `192.168.1.226/24`; default route via `192.168.1.1`.
  `pve_bridge: vmbr0` in `group_vars/autobase.yml` matches.
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

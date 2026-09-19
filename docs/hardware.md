# tav-serv hardware inventory

Hardware snapshot as of 2026-07-05; OS section updated for the Proxmox rebuild.
See also: [../ansible/host_vars/tav-serv.yml](../ansible/host_vars/tav-serv.yml).

## OS

- **Proxmox VE 9** (Debian 13 trixie base)
- Previously Linux Mint 22.3 + VirtualBox; that era's software inventory is kept
  at [context/tav-serv-inventory.md](context/tav-serv-inventory.md) as history
- Administered as `root`; Ansible connects with the `ansible_control` key
- Partitioning and swap are the PVE installer's, not Ansible's

## Chassis

- Dell PowerEdge R610
- BIOS 6.4.0 (2013-07-23) — final for the platform is 6.6.0 (Feb 2018)
- iDRAC6 firmware 2.85, static `192.168.0.120` (shared LOM mode currently)
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

## Storage

- PERC H700 hardware RAID controller
- **Current:** RAID 0 across 2× Seagate `ST91000640NS` (1 TB 2.5" SAS 7200 rpm)
  - Deliberate no-redundancy scratch config
  - SMART clean: Reallocated=1 baseline, no pending/uncorrectable, ~6100 PoH, temps 34-35°C
- **Pending:** 3× Intel `SSDSC2BX800G4R` (S3610 800 GB, Dell firmware, DWPD 3)
  - Offer submitted @ $85/3, contingent on SMART reports

## Networking

- 4× Broadcom BCM5709 gigabit (`eno1`-`eno4`); one in use, enslaved to PVE's
  `vmbr0` bridge — confirm which with `ip -br addr` and
  `/etc/network/interfaces`, and set `pve_bridge` in `group_vars/autobase.yml`
  to match
- iDRAC on `192.168.0.120`, LAN `192.168.0.0/24`
- MagicDNS name `tav-serv`; tav-serv is the tailnet subnet router for the LAN.
  Its tailnet IP changed when the node was re-registered during the rebuild —
  read it from `tailscale status`, don't rely on a written-down value.

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

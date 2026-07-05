# Tav-Serv hardware inventory

Snapshot as of 2026-07-05. See also: [../ansible/host_vars/tav-serv.yml](../ansible/host_vars/tav-serv.yml).

## Chassis

- Dell PowerEdge R610
- BIOS 6.4.0 (2013-07-23) — final for the platform is 6.6.0 (Feb 2018)
- iDRAC6 firmware 2.85, static `192.168.0.120` (shared LOM mode currently)
- Enterprise iDRAC card physically present per BMC sensor; license status TBD

## CPU

- Socket 1: 1× Intel Xeon **X5670** (6c/12t, Westmere-EP, LGA 1366, 95W)
- Socket 2: **empty** — matching X5670 (SLBV7) ordered, heatsink PN GY611 pending

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

- 4× Broadcom BCM5709 gigabit (`eno1`-`eno4`); only `eno3` in use
- iDRAC on `192.168.0.120`, LAN `192.168.0.0/24`
- Tailscale IP `100.80.216.116` (`tav-serv` MagicDNS name)

## Virtualization capabilities

- VT-x present (`vmx` flag)
- VT-d / IOMMU enabled + interrupt remapping active
- Notable IOMMU groups:
  - Group 13: `01:00.0`/`.1` — first two BCM5709 NICs
  - Group 14: `02:00.0`/`.1` — second two BCM5709 NICs
  - Group 9: `03:00.0` PERC H700 (+ root port)

## Power / thermal

- Ambient 28°C, planar readings healthy
- Power restore policy: always-on

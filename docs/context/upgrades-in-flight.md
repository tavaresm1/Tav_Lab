# Hardware upgrades ordered but not yet installed

Snapshot as of 2026-07-05; the rebuild flow updated for Proxmox VE. Track
post-install verification steps here so whoever installs the parts knows what to
check.

Note on the CPU: the X5670 is Westmere-EP with **no AVX**, which caps the box at
the `x86-64-v2` microarchitecture level. Adding a second one doesn't change that.
It is why the guests run Ubuntu rather than a RHEL 10 rebuild — see
`design-decisions.md`.

## Second CPU — DONE (discovered 2026-09-19)

**This is already installed.** The `proxmox_host` baseline reported 24 vCPU, and a
single 6c/12t X5670 cannot produce that. The section below is kept as the
post-install checklist — run it to confirm the pair is healthy, since it was
apparently installed without anyone recording it here.

- **Part:** Intel Xeon **X5670** (SLBV7), used from eBay
- **Purpose:** Populate empty socket 2 for a full 2× X5670 config
- **Also needed:**
  - Matching heatsink for socket 2 — Dell PN GY611 (or TY709 / 1PVN2)
  - Thermal paste (MX-4 or Kryonaut)
  - Remove the plastic airflow shroud over socket 2 before install

### Post-install checks

```bash
# Socket count and total logical CPUs
lscpu | grep 'Socket(s)'                       # expect 2
grep -c '^processor' /proc/cpuinfo             # expect 24

# Confirm QPI still at 6.4 GT/s (Westmere-EP native)
dmidecode -t processor | grep -i 'current speed'
```

If either CPU downclocks or POST warns about mismatched steppings, verify
both are SLBV7. Any other X5670 stepping is nominally allowed but Dell
BIOS is picky and will occasionally downclock the pair.

## RAM → 96 GB (planned 2026-09-18)

**The box is already at 40,188 MB, not the 24 GB this document was written
against** — DIMMs were added at some point and never recorded here. The current
population is unknown; `dmidecode -t memory` is the way to find out, and doing
that *before* ordering matters because it decides which of the routes below is
even available.

Target is **96 GB**. Two ways to get there on an R610, which has 18 slots, 9 per
socket, 3 channels per socket:

| Route | Config | Speed | Notes |
|---|---|---|---|
| 8 GB RDIMMs | 12× 8 GB, 6 per bank (2 DIMMs per channel) | 1066 MT/s | **Preferred** — 8 GB DDR3 RDIMMs are the cheap, plentiful size |
| 16 GB RDIMMs | 6× 16 GB, 3 per bank (1 DPC) | 1333 MT/s | Full speed, fewer sticks, leaves 12 slots free for later |

**Both banks are live** — the second X5670 is already installed (24 threads
reported by the baseline on 2026-09-19; see `../hardware.md`), so socket 2's memory
controller is up and its 9 slots work. Both routes above are available.

Going to 2 DIMMs per channel drops 1333 → 1066 MT/s; 3 DPC forces 800 MT/s, so
avoid it. Populate each bank in multiples of three to keep triple-channel;
populating in pairs costs ~15% memory bandwidth. The 16 GB route is the only one
that keeps 1333 MT/s, which is worth the price premium on a box whose workload is
Postgres.

Once 96 GB is in: the Autobase platform's 9728 MB stops being tight (see
`../hardware.md#memory` for the current 34,928-of-40,188 arithmetic), the trimmed
guests can have their memory back, the 8 GB `zfs_arc_max` cap becomes sensible
rather than greedy, and there is headroom to raise `pgnode` memory if a cluster
needs it. Re-measure and update `../hardware.md`, the top-level `README.md` and
the sizing note in `inventory/group_vars/autobase.yml` — all three currently
document the 40 GB squeeze.

### CPU2 RAM bank (ordered under the old 48 GB plan)

- **Part:** Hynix `HMT351R7BFR4C-H9` — 4 GB 1Rx4 PC3-10600R DDR3 RDIMM 1.5V
- **Quantity:** Lot of 8 (6 for the bank + 2 spares)
- **Grade:** B (R2v3 REC categories C5/C6/F4/F5), 30-day return
- **Rank note:** Existing CPU1 bank is Kingston 1R (`9965433-034.A00LF`).
  Cross-socket rank mismatch would be a problem; both are 1Rx4 so all good.

Populate all six CPU2 slots (`B1`-`B6`) in one shot to preserve triple-channel.
Do not populate in pairs — that drops the bank to dual-channel with a ~15%
memory bandwidth penalty.

### Post-install checks

```bash
# All 12 slots should report same speed and rank
sudo dmidecode -t memory \
  | grep -E "^\s*(Size|Configured Memory Speed|Rank)" \
  | grep -v "No Module"
```

Every populated slot: `4 GB / 1333 MT/s / Rank 1`. Anything at 1066 MT/s
or wrong rank indicates a bad DIMM or channel population issue.

These 4 GB sticks were bought to take the box 24 GB → 48 GB. That plan is
superseded: the box is already at 40 GB and the target is 96 GB. Since both sockets
turned out to be populated, some of this lot may already be installed — which would
explain the 40 GB. Installing the rest buys +4 GB per slot and blocks both 96 GB
routes above, so keep them as spares and run `dmidecode -t memory` before deciding
anything.

## SSDs — repurposed: replace Big_Data1's worn members

> **The premise of this section changed on 2026-09-19.** There is no "current HDD
> pair" — the PERC volume runs on 4× Intel S3500 600 GB SSDs and the box holds 20
> SSDs in total. But the first real wear reading found `Big_Data1` (the pool that
> actually holds data, and raidz1 so single-parity) has four of eight members under
> 50% endurance remaining, with `/dev/sdb` at **028 and 2 reallocated sectors**.
> See `../hardware.md` for the full table.
>
> So these three drives are worth buying after all — not for a RAID rebuild, but as
> one-at-a-time `zpool replace` stock for `Big_Data1`'s worst members. That is an
> online operation and needs no rebuild flow at all. The SMART-verification table
> below is still exactly the right thing to demand from the seller; ignore the
> RAID-level discussion and the rebuild sequence unless you are separately
> rebuilding the PERC volume.

- **Part:** Intel `SSDSC2BX800G4R` — S3610 800 GB, Dell-firmware variant
  (Dell PN `9F3GY` / `09F3GY`)
- **Quantity:** 3 (offer submitted @ $85 total, contingent on SMART reports)
- **Class:** SATA III enterprise, 3 DWPD mixed-use, 1-year seller warranty

### Why three drives

Third drive gives options:
- **Hot spare** in the PERC (only useful if you switch to RAID 1 / RAID 5)
- **RAID 5** across all three: 1.6 TB usable, single-drive fault tolerance,
  minimal write penalty with SSD backing
- **Cold spare** on a shelf

Recommendation for this box is **RAID 5** across all three at rebuild time.
The current RAID 0 config was a deliberate scratch choice — with three
matched SSDs available, the cost of redundancy is essentially free.

### PERC H700 caveats with SSDs

- No TRIM/UNMAP passthrough — enterprise SSDs with strong garbage collection
  are required. S3610 handles this fine.
- Backplane negotiates SATA at 3 Gb/s (SATA II), so sequential caps ~270 MB/s.
  Random IOPS unaffected (this is what matters for VMs/containers).
- Dell-firmware SSDs (the `R` suffix) skip the "non-Dell drive" POST warning.

### SMART verification (do before installing)

Ask the seller for the SMART output on each drive. Look at:

| Attribute                        | Healthy range        | Notes                                    |
|----------------------------------|----------------------|------------------------------------------|
| `233 Media_Wearout_Indicator`    | >80 (ideally >90)    | 50-80 fine for homelab; <40 negotiate    |
| `5 Reallocated_Sector_Ct`        | 0                    | Non-zero is unusual on SSDs              |
| `183 SATA_Downshift_Count`       | 0                    | Non-zero = cable/port issues in prior host |
| `184 End-to-End_Error`           | 0                    | Non-zero = firmware or DRAM concern      |
| `241 Total_LBAs_Written`         | <500-800 TBW ideal   | S3610 rated ~4.4 PBW; wear is what matters |
| `Power_On_Hours`                 | any (SSDs don't age from PoH) | Info only                     |

### Rebuild flow when drives arrive

1. **Backup** to the QNAP over Tailscale first. `vzdump` every guest you intend
   to keep — TrueNAS (VM 100), the Minecraft guest, and the Autobase console VM
   if you don't want to recreate its clusters — plus `/etc/pve` and the host's
   `/etc`. The `pgnode` guests are disposable: they come back from
   `playbooks/autobase.yml` and the clusters get recreated from the Console.
2. Power off, swap the two current 1 TB HDDs for two of the SSDs. Third SSD
   goes in slot 2 (RAID 5 member) or stays on a shelf as a cold spare.
3. Boot into PERC BIOS (`Ctrl-R` at POST), delete old VD, create new VD
   as RAID 5 across all three drives. Fast Init is fine on SSDs.
4. Set Write policy to `Write Through` on the new VD (SSDs handle their
   own caching; H700 write-back with BBU actually hurts SSD latency).
5. Disable disk cache in the drive properties.
6. Boot the **Proxmox VE 9 installer** from USB. Hostname `tav-serv`, static IP
   on the lab LAN. The installer handles partitioning and swap — nothing in this
   repo does.
7. Install the control-node pubkey into `/root/.ssh/authorized_keys` (PVE web UI
   Shell at `https://tav-serv:8006`, or iDRAC if the network is down).
   `control-node/README.md` step 3.
8. `ansible-playbook playbooks/proxmox-host.yml`, then re-approve the
   `192.168.1.0/24` subnet route in the Tailscale admin console — re-registering
   the node drops the old approval.
9. Restore the guests from `vzdump`, then rebuild the Postgres platform from
   `docs/autobase.md`.

The full version of this, not tied to the SSD swap, is the rebuild runbook in the
top-level `README.md`.

## Also on the wishlist (not ordered)

- iDRAC Enterprise license (~$5-10 on eBay) — unlocks virtual media + full
  KVM, worth it for a headless VM host. Only needed if not already licensed
  — sensor `iDRAC6 Ent PRES = 0x2` suggests the Enterprise card is already
  physically present.
- BIOS update to 6.6.0 (Feb 2018, Dell's final for R610). Not urgent.

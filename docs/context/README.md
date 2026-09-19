# Project context

Background documents that explain *why* the repo looks the way it does.
Companion to the operational docs in `../hardware.md` and the roles under
`../../ansible/`.

| File                    | What it captures                                                       |
|-------------------------|------------------------------------------------------------------------|
| `design-decisions.md`   | Every deliberate choice, with reasoning — start here                   |
| `tailscale-topology.md` | How tav-serv, tavares-lab, the console VM and the QNAP relate          |
| `upgrades-in-flight.md` | Hardware ordered but not yet installed, with post-install checklists   |
| `workflow-notes.md`     | Working preferences: batching, breaks, network debugging               |
| `tav-serv-inventory.md` | **Historical.** Software + workload inventory from the Linux Mint era, superseded by the Proxmox rebuild. Kept so the rebuild can be reasoned about, not as a target state. |

These files are versioned so any future rebuild has the same background any
current operator has — no "you had to be there" gaps.

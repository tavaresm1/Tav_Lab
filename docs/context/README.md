# Project context

Background documents that explain *why* the repo looks the way it does.
Companion to the operational docs in `../hardware.md` and the roles under
`../../ansible/`.

| File                                | What it captures                                          |
|-------------------------------------|-----------------------------------------------------------|
| `tav-serv-inventory.md`             | Full software + running-workload inventory as of 2026-07-05 |
| `upgrades-in-flight.md`             | Hardware ordered but not yet installed, with post-install checklists |
| `design-decisions.md`               | Ansible scope, auth model, control-node choice — with reasoning |
| `tailscale-topology.md`             | How Tav-Serv, workstation, and QNAP relate on the tailnet |
| `workflow-notes.md`                 | Working preferences: batching, breaks, network debugging  |

These files are versioned so any future rebuild has the same background any
current operator has — no "you had to be there" gaps.

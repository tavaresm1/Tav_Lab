# Design decisions

The choices that shaped how the repo and the box look today, with the
reasoning behind each one. Read this before pushing back on any of them —
some are deliberate trade-offs, not accidents.

## RAID 0 across two HDDs (current) → RAID 5 across three SSDs (planned)

**Current state:** RAID 0 across 2× 1 TB SAS HDDs, no redundancy.
**Reasoning:** Deliberate scratch config for a "learn and stage" box that
gets rebuilt on the way to a real platform. Zero redundancy is cheaper than
RAID 1 in terms of usable capacity, and rebuild-from-scratch is fast when
the OS is codified in this repo.

**On upgrade:** Move to RAID 5 across three S3610 800 GB SSDs.
Reasoning: three matched drives arrive together, parity write penalty is
negligible on SSDs, and the box graduates from scratch to persistent.

## Ansible over Terraform for VMs

**Choice:** VM declarations live in `roles/virtualization/tasks/main.yml`
using `VBoxManage` shell-outs, not Terraform's libvirt/virtualbox providers.

**Reasoning:** One host, one operator, VMs get created rarely. The overhead
of maintaining a second tool (state file, provider install, apply cycle)
isn't worth it at this scale. If the fleet grows past ~3 hosts, revisit.

**Trade-off accepted:** VBox VMs are create-only in this role — the tasks
don't reconcile drift on running VMs. Post-creation edits are intentional
and manual. This is fine for a homelab; less fine for production.

## Public github.com repo

**Choice:** Public repo at `github.com/tavaresm1/Tav_Lab`.

**Reasoning:** Personal homelab, separated from `github.mathworks.com` which
is for MathWorks work only. Public also lets the repo double as documentation
for anyone else running an R610 homelab.

**Trade-off accepted:** Every secret has to live in `ansible-vault` and be
gitignored. The Tailscale auth key, any SMTP creds for smartd alerts, and
similar must never be committed in plaintext. See the top-level README for
vault usage.

## NOPASSWD sudo grant on Tav-Serv

**Choice:** `tavaresm1 ALL=(ALL) NOPASSWD:ALL` at
`/etc/sudoers.d/90-tavaresm1-nopasswd`.

**Reasoning:** The alternatives are `--ask-become-pass` per playbook run
(constant friction) or vault-stored sudo password (still adds a prompt for
the vault password). NOPASSWD is the cleanest for a homelab where the
control-node SSH key is the trust anchor.

**Trade-off accepted:** If the control-node SSH key is compromised, so is
root on Tav-Serv. Mitigated by:
- Dedicated per-host SSH keypair (`control-node/ssh_keys/ansible_control`)
- Key never leaves the control-node host
- Each control-node host is authorized independently on Tav-Serv, so any
  one key can be revoked without disrupting the others

## Containerized control node

**Choice:** Ansible runs from an Alpine-based Docker container defined in
`control-node/`, not from a system-installed Ansible.

**Reasoning:**
- Portable across Linux, Windows Docker Desktop, macOS, WSL, and Tav-Serv
  itself. No "install Ansible on your workstation" prerequisite.
- Bundled collection versions match what the roles expect — no drift from
  the host's system Ansible.
- Each control-node host gets its own SSH key, its own build, its own
  lifecycle. Zero shared state.

**Trade-off accepted:** Docker Desktop on Windows/macOS needs host networking
opted-in for the container to inherit the host's Tailscale connection. If
that's not available, the container falls back to bridge networking with a
NAT hop — works, slightly slower.

## Openbox cleanup deferred

**Choice:** `openbox`, `obconf`, `tint2`, `lxappearance`, `lxterminal`,
`pcmanfm`, and various LXDE bits stayed installed on 2026-07-05, listed in
`cleanup_packages` for Ansible to remove on next apply.

**Reasoning:** The user opted to leave them for now rather than run the
removal manually. Codifying them in `cleanup_packages` means they'll be
purged on next apply automatically, without a separate manual step.

## Docker stacks live inline in host_vars

**Choice:** Each stack's compose file is embedded as a multi-line YAML
string under `docker_stacks` in `host_vars/tav-serv.yml`.

**Reasoning:** With one or two stacks, it's less scaffolding than a
separate `templates/*.j2` per stack. Inline keeps the config for a stack
close to its declaration.

**Trade-off accepted:** Doesn't scale. When the stack count crosses ~5-10,
split into `roles/docker/templates/<stack>.compose.yml.j2` and reference
them from `host_vars`.

## Tailscale flag drift handled via `tailscale set`

**Choice:** The Tailscale role runs `tailscale up` only on first login
(detected via `tailscale status --json`), otherwise uses `tailscale set`
for flag drift.

**Reasoning:** Re-running `tailscale up` with different flags works but
generates auth prompts and log churn. `tailscale set` is designed for
idempotent flag updates on an already-authenticated node.

## Not tracked in this repo

Deliberate scope exclusions:

- **iDRAC config** beyond a password reset — hardware BMC lifecycle is
  separate from the OS. Not worth automating for one node.
- **BIOS updates** — manual via Dell DUP or Lifecycle Controller.
- **Guest OS state inside VMs** — the VM is provisioned by this repo, but
  whatever runs *inside* HAOS (or future VMs) is managed by that VM's own
  tooling.
- **Backups themselves** — a separate concern. This repo defines the box;
  a separate backup tool (rsync/borg to the QNAP over Tailscale) handles
  data protection.
- **Ephemeral fixups** — anything only useful during a debug session.
  If it needs to survive a rebuild, it goes in a role.

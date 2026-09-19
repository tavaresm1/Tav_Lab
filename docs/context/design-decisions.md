# Design decisions

The choices that shaped how the repo and the box look today, with the
reasoning behind each one. Read this before pushing back on any of them —
some are deliberate trade-offs, not accidents.

## tav-serv is a Proxmox host now; the Mint-era roles are retired

**Choice:** The R610 keeps the name `tav-serv` but runs Proxmox VE 9 (Debian 13)
instead of Linux Mint 22.3. The roles that configured it as a Mint box were
removed rather than made conditional: `base`, `monitoring`, `virtualization`,
`user_env`. `roles/proxmox_host` replaces them with a much smaller surface.

**What went, and why:**

| Removed | Why |
|---|---|
| `roles/base` — Mint apt sources, Openbox/LXDE purge, 8 GB swapfile, unattended-upgrades | No desktop on a hypervisor; PVE sets up swap on LVM at install; unattended apt moving kernels and qemu under running guests is not something you want at 06:00 |
| `roles/virtualization` — libvirt + VirtualBox + the `haos` VM | PVE *is* the hypervisor. A second stack underneath it is redundant at best. |
| `roles/monitoring` — Cockpit | PVE's own UI is on `:8006`. smartd survived, folded into `roles/proxmox_host`. |
| `roles/user_env` — `tavaresm1` dotfiles and authorized_keys | PVE is administered as root; there is no interactive login user to furnish. |
| `docker_stacks: dockhand` in `host_vars/tav-serv.yml` | Container workloads belong in a guest, not on the hypervisor. |

**Reasoning:** Keeping the old roles behind `when: ansible_distribution == ...`
guards would have meant carrying two OS idioms forever for a single host, and
every one of them was written against assumptions (a desktop, a swapfile, a
non-root admin user, VirtualBox) that the rebuild invalidated. `git log` is a
better archive than a dead code path.

**Trade-off accepted:** Anyone wanting the Mint configuration back has to read
git history rather than flip a variable. The software inventory from that era is
preserved in `tav-serv-inventory.md` for reference.

## The control node runs on the workstation, not on the hypervisor

**Choice:** The `control-node` container runs on `tavares-lab` (the Windows
workstation) and reaches tav-serv over the tailnet. Docker is deliberately not
installed on the Proxmox node.

**Reasoning:** Docker CE rewrites iptables/nftables and manages its own bridges,
which collides with PVE's firewall and `vmbr0` — a class of failure that takes
the whole lab down, not one service. The workstation already has the repo
checkout, the vault password and the SSH keys. And the control node's first job
is *building* the guests, so it cannot live inside one.

**Trade-off accepted:** Ansible runs depend on the workstation being awake. That
is fine for provisioning, which is interactive anyway. If scheduled day-2
`vitabaks.autobase` runs become a want, the place for them is a container on the
`autobase-console` VM, which already runs Docker and already has SSH to all three
DB nodes — an addition, not a move.

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

**Choice:** VM declarations live in Ansible — `group_vars/autobase.yml` plus
`roles/proxmox_guests` — not in Terraform's `bpg/proxmox` provider.

**Reasoning:** One host, one operator, VMs get created rarely. The overhead
of maintaining a second tool (state file, provider install, apply cycle)
isn't worth it at this scale. If the fleet grows past ~3 hosts, revisit.

**Trade-off accepted:** No state file, so no real drift detection. The
mechanics of how that is mitigated on Proxmox are in "Autobase guests: Ansible +
community.proxmox" below. This decision predates the rebuild — it was originally
made for the VirtualBox `haos` VM under Mint — and survived it unchanged, which
is a reasonable sign it was right.

## Public github.com repo

**Choice:** Public repo at `github.com/tavaresm1/Tav_Lab`.

**Reasoning:** Personal homelab, separated from `github.mathworks.com` which
is for MathWorks work only. Public also lets the repo double as documentation
for anyone else running an R610 homelab.

**Trade-off accepted:** Every secret has to live in `ansible-vault` and be
gitignored. The Tailscale auth key, any SMTP creds for smartd alerts, and
similar must never be committed in plaintext. See the top-level README for
vault usage.

## SSH key as the trust anchor; no interactive sudo prompt anywhere

**Choice:** Ansible connects to tav-serv **as root** — that is how PVE is
administered and there is no second account on it. On the guests it connects as
`ansible`, which `roles/guest_baseline` grants `NOPASSWD:ALL` via
`/etc/sudoers.d/90-ansible-nopasswd`.

**Reasoning:** The alternatives are `--ask-become-pass` per playbook run
(constant friction) or a vault-stored sudo password (which still adds a prompt,
for the vault). The SSH key is already the thing that has to be protected; adding
a sudo password in front of it buys nothing when the same key can read the
sudoers file.

**Trade-off accepted:** Whoever holds `control-node/ssh_keys/ansible_control`
has root on the hypervisor, and whoever holds `ssh_keys/autobase` has root on
every guest. Mitigated by:
- Two separate keypairs, so either trust path can be revoked alone
- Keys never leave the control-node host (gitignored, mounted read-only)
- Each control-node host is authorized independently, so one key can be revoked
  without disrupting the others

Pre-rebuild this was `tavaresm1 ALL=(ALL) NOPASSWD:ALL` on the Mint box; the
reasoning carried over verbatim, only the account changed.

## Containerized control node

**Choice:** Ansible runs from an Alpine-based Docker container defined in
`control-node/`, not from a system-installed Ansible.

**Reasoning:**
- No "install Ansible on your workstation" prerequisite, and it works the same
  on Linux, Windows Docker Desktop, macOS and WSL. (Not on the hypervisor — see
  the control-node placement decision above.)
- Bundled collection versions match what the roles expect — no drift from
  the host's system Ansible.
- Each control-node host gets its own SSH key, its own build, its own
  lifecycle. Zero shared state.

**Trade-off accepted:** Docker Desktop on Windows/macOS needs host networking
opted-in for the container to inherit the host's Tailscale connection. If
that's not available, the container falls back to bridge networking with a
NAT hop — works, slightly slower.

## Docker stacks are declared inline, one variable per host

**Choice:** `roles/docker` takes a `docker_stacks` list where each stack's
compose file is an inline multi-line YAML string, set in the group_vars or
host_vars of whichever host runs it.

**Reasoning:** With one or two stacks, it's less scaffolding than a separate
`templates/*.j2` per stack. Inline keeps a stack's config next to its
declaration.

**Trade-off accepted:** Doesn't scale. When the stack count crosses ~5-10, split
into `roles/docker/templates/<stack>.compose.yml.j2` and reference those instead.
The Autobase Console already deviates, for a different reason — see below.

**Note:** the original consumer of this was the `dockhand` stack in
`host_vars/tav-serv.yml`, which went away with the Proxmox rebuild (containers
belong in a guest, not on the hypervisor). The convention stands and
`roles/docker` still implements it; there is currently no host using it.

## Tailscale flag drift handled via `tailscale set`

**Choice:** The Tailscale role runs `tailscale up` only on first login
(detected via `tailscale status --json`), otherwise uses `tailscale set`
for flag drift.

**Reasoning:** Re-running `tailscale up` with different flags works but
generates auth prompts and log churn. `tailscale set` is designed for
idempotent flag updates on an already-authenticated node.

## Autobase guests: Ansible + community.proxmox, not Terraform

**Choice:** The four Ubuntu guests backing the Autobase platform are declared
in `group_vars/autobase.yml` and built by `roles/proxmox_guests` using
`community.proxmox.proxmox_kvm`, not Terraform's `bpg/proxmox` provider.

**Reasoning:** Consistent with the "Ansible over Terraform for VMs" decision
above — still one host, one operator. Terraform would genuinely be better at
repeatable cloud-init clones (real state, drift detection), but it costs a
second toolchain for four VMs.

**Trade-off accepted:** No state file means no drift detection. The role
compensates where it matters: `update: true` reapplies sizing and cloud-init on
every run, and `proxmox_disk` reconciles disk size. Nothing reconciles NIC or
storage changes — those stay manual.

**Note:** The Proxmox modules were migrated out of `community.general` and
removed from it in 11.0.0. `community.general.proxmox_kvm` no longer resolves;
the FQCN is `community.proxmox.proxmox_kvm`. Pinned in
`ansible/requirements.yml`.

## Cloud-init template built with `qm`, guests built over the API

**Choice:** `roles/proxmox_template` shells out to `qm` on the node;
`roles/proxmox_guests` talks to the PVE REST API from the control node.

**Reasoning:** `qm importdisk` has no module equivalent — a downloaded qcow2 has
to be imported through the CLI, on the node. Everything after that (clone,
config, resize, start) is a clean API operation. The template role reads the
imported volume ID back out of `qm config` rather than constructing it, because
the volid format differs by storage backend (`local-lvm:vm-8000-disk-0` vs
`local:8000/vm-8000-disk-0.qcow2`).

**Trade-off accepted:** Two credential paths — an SSH key for the node and an
API token for the modules.

## Autobase console compose fetched at a pinned tag, not vendored inline

**Choice:** `roles/autobase_console` pulls upstream's `console/docker-compose.yml`
at tag `{{ autobase_console_version }}`, breaking the `docker_stacks`
inline-compose convention above.

**Reasoning:** It is a four-service file that upstream maintains and version-bumps.
Vendoring it inline means hand-merging every release; fetching it at a tag makes
an upgrade a one-variable change. This is the split the `docker_stacks` decision
already anticipated, arriving earlier than the ~5-10 stack mark because of the
file's size and provenance rather than the stack count.

**Trade-off accepted:** The compose content is not visible in this repo, and a
run needs network access to raw.githubusercontent.com.

## Ubuntu 24.04 LTS for the Autobase guests, not Rocky 10

**Choice:** All four platform guests run Ubuntu Server 24.04 LTS.

**Reasoning:** Rocky 10 was the original choice and did not boot on tav-serv. RHEL 10
and its rebuilds raised the baseline to `x86-64-v3` (AVX2, BMI2, FMA, Haswell and
later); the kernel refuses to start on older silicon or under a VM CPU type that
masks those flags, and it does so before anything reaches a console. Ubuntu 24.04
still targets `x86-64-v2`, so it runs on the same hardware unchanged. Autobase's
CI tests Ubuntu 24.04 daily, so nothing is lost on the support side.

Rocky **9** is also `x86-64-v2` and would most likely have booted, but Ubuntu
keeps the whole platform on one package idiom as PVE itself and removes the second
`dnf`/`apt` code path from the roles.

**Consequence for the roles:** there is no shared baseline role any more.
`roles/proxmox_host` baselines the Debian hypervisor and `roles/guest_baseline`
baselines the Ubuntu guests; the two have almost nothing in common beyond
timezone, so sharing one role would have meant conditionals throughout. The
Docker and Tailscale apt repos live inside `roles/docker` and `roles/tailscale`
rather than in a baseline role, so each stands alone; both map the distribution
codename through a role default, because Tailscale and Docker publish separate
per-distro, per-codename repos and the hypervisor (`debian`/`trixie`) and the
guests (`ubuntu`/`noble`) need different ones.

**Not applicable any more:** with Ubuntu there is no SELinux, so the earlier
decision to keep it `Enforcing` while disabling Docker's labelling is moot.
AppArmor is left at its Ubuntu default; Docker ships its own profile and the
Console's `/var/run/docker.sock` bind-mount needs no extra handling.

## Not tracked in this repo

Deliberate scope exclusions:

- **PVE's own configuration** — storage, bridges, cluster membership, firewall.
  Second-guessing the hypervisor from Ansible is how you lose a hypervisor.
- **iDRAC config** beyond a password reset — hardware BMC lifecycle is
  separate from the OS. Not worth automating for one node.
- **BIOS updates** — manual via Dell DUP or Lifecycle Controller.
- **Pre-existing guests** — TrueNAS SCALE (VM 100) and the Minecraft/BlueMap
  server predate this repo and are not managed by it.
- **Guest OS state inside VMs** — the VM shell is provisioned by this repo, but
  whatever runs *inside* it (PostgreSQL, TrueNAS, the Console's own containers)
  is managed by that guest's own tooling.
- **Backups themselves** — a separate concern. This repo defines the box;
  a separate backup path (`vzdump` + rsync/borg to the QNAP over Tailscale)
  handles data protection.
- **Ephemeral fixups** — anything only useful during a debug session.
  If it needs to survive a rebuild, it goes in a role.

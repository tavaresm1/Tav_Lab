# Tav_Lab

Tavares HomeLab — Infrastructure-as-code for **Tav-Serv**, a Dell PowerEdge R610
homelab hypervisor running Linux Mint 22.3 (Ubuntu 24.04 noble base).

The single source of truth for what packages, containers, VMs, and configs live
on the box. If it's not in this repo, it's not supposed to be on the server.

---

## Repo layout

```
ansible/                       Ansible root
  ansible.cfg                  Defaults (inventory, ssh args, become)
  inventory/hosts.ini          Static inventory (currently just tav-serv)
  group_vars/all.yml           Non-secret vars for all hosts
  host_vars/tav-serv.yml       Host-specific vars (hardware, VMs, stacks)
  site.yml                     Top-level playbook — applies every role
  playbooks/
    ping.yml                   Sanity: does Ansible reach the target
  roles/
    base/                      apt sources, packages, sysctl, unattended-upgrades, swapfile
    monitoring/                Cockpit + smartd for the PERC-attached disks
    docker/                    Docker CE + declarative container stacks
    virtualization/            libvirt/KVM + VirtualBox + VM definitions
    tailscale/                 Tailscale package + `up` flags + subnet routes
    user_env/                  ~/.ssh/authorized_keys, dotfiles, tmux config
control-node/
  Dockerfile                   Alpine + Ansible + git + openssh-client
  entrypoint.sh                Clones/pulls Tav_Lab on start
  docker-compose.yml           Launches the control node against Tav-Serv
  README.md                    Bootstrap steps for the control node
docs/
  hardware.md                  Physical inventory of the box
```

---

## Prerequisites

### On the control node (where you run `ansible-playbook`)

**Recommended:** use the containerized control node in `control-node/`. It
runs on any Docker host (Linux, Windows Docker Desktop, macOS, WSL, or
Tav-Serv itself) and bundles Ansible + its collections + the SSH client.
See [control-node/README.md](control-node/README.md) for full bootstrap.

Prerequisites for the containerized path:
- Docker Engine or Docker Desktop 24+
- git
- Network reachability to Tav-Serv (typically via Tailscale)

**Alternative:** run Ansible natively on the control-node host. Needs:
- Python 3.10+
- `ansible-core >= 2.16`
- Collections: `ansible.posix`, `community.general`, `community.docker`
- SSH client with a private key authorized on `tavaresm1@tav-serv`

Install (Debian/Ubuntu/Mint):
```bash
sudo apt install -y ansible ansible-lint
ansible-galaxy collection install ansible.posix community.general community.docker
```

### On Tav-Serv (target)

- Linux Mint 22.3 (Ubuntu 24.04 noble base) freshly installed
- OpenSSH server reachable (default port 22)
- User `tavaresm1` with:
  - `sudo` privileges
  - **NOPASSWD sudo** grant (see rebuild runbook below)
  - The control node's SSH pubkey in `~/.ssh/authorized_keys`
- Networking configured enough that Tav-Serv can reach `download.docker.com`,
  `pkgs.tailscale.com`, and Ubuntu mirrors

That's it — nothing else needs to be hand-installed. Every additional package
and service in the current inventory is declared in this repo.

---

## Control node

Ansible runs from a dedicated container defined in `control-node/`. The
container is **portable** — build it on any Docker host (your workstation,
a laptop, WSL, another Linux box, or Tav-Serv itself). Full walkthrough,
including per-platform notes for Docker Desktop on Windows/macOS, is in
[control-node/README.md](control-node/README.md).

Shape of the bootstrap:

```bash
git clone https://github.com/tavaresm1/Tav_Lab.git
cd Tav_Lab/control-node

# Generate a dedicated SSH keypair for this control-node host
mkdir -p ssh_keys && chmod 700 ssh_keys
ssh-keygen -t ed25519 -f ssh_keys/ansible_control -N '' \
           -C "ansible-control@$(hostname)"

# Get ssh_keys/ansible_control.pub into tavaresm1@tav-serv:~/.ssh/authorized_keys
# (via SSH, another machine that can reach it, or the iDRAC virtual console)

docker compose build
docker compose run --rm ansible ansible -i inventory/hosts.ini all -m ping
```

## Usage

From the control node container (from `~/Tav_Lab/control-node/` on Tav-Serv):

```bash
# Sanity ping (no changes)
docker compose run --rm ansible \
    ansible -i inventory/hosts.ini all -m ping

# Dry-run (show what would change)
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml --check --diff

# Apply everything
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml

# Apply one slice only
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml --tags base

# Interactive shell in the container
docker compose run --rm ansible bash
```

Available tags: `base`, `cleanup`, `sysctl`, `swap`, `unattended`, `cockpit`,
`smart`, `docker`, `stacks`, `virtualization`, `libvirt`, `vbox`, `vms`,
`tailscale`, `net`, `user_env`, `ssh`, `tmux`.

---

## What this project tracks (dependency inventory)

Every third-party thing installed on Tav-Serv is declared here. If you find
something on the box that isn't in this list, it either needs to be added to a
role or removed from the box.

### apt repositories

| Repo                        | Managed by role   | Purpose                             |
|-----------------------------|-------------------|-------------------------------------|
| Ubuntu noble main/updates   | (base OS install) | Distro packages                     |
| Linux Mint `zena`           | (base OS install) | Mint-specific overlays              |
| `download.docker.com`       | `base`            | Docker CE                           |
| `pkgs.tailscale.com`        | `base`            | Tailscale                           |

### System packages (installed via apt)

Declared in `group_vars/all.yml`.

**Base utilities** (`base_packages`):
htop, bottom, ncdu, tmux, iotop, iftop, lsof, strace, tree, pv, rsync, jq,
unzip, curl, ca-certificates, gnupg, apt-transport-https.

**Hardware / monitoring** (`hardware_packages`):
smartmontools, ipmitool, freeipmi-tools, lm-sensors.

**Cockpit** (`cockpit_extras`):
cockpit, cockpit-machines, cockpit-pcp, cockpit-storaged,
cockpit-networkmanager, cockpit-packagekit.

**Docker CE stack**:
docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin,
docker-compose-plugin.

**Virtualization**:
qemu-kvm, libvirt-daemon-system, libvirt-clients, bridge-utils, virtinst,
genisoimage, virtualbox, virtualbox-ext-pack, virtualbox-guest-utils.

**Tailscale**: tailscale.

**Unattended upgrades**: unattended-upgrades, apt-listchanges.

**Removed** (Openbox/LXDE leftovers, `cleanup_packages`):
openbox, obconf, tint2, lxappearance, lxterminal, lxde-settings-daemon,
lxde-icon-theme, lxmenu-data, libmenu-cache-bin, libmenu-cache3,
libobrender32v5, libobt2v5, pcmanfm.

### Docker container stacks

Declared in `host_vars/tav-serv.yml` under `docker_stacks`. Currently:

| Stack     | Image                              | Ports   | Notes                          |
|-----------|------------------------------------|---------|--------------------------------|
| dockhand  | `fnsys/dockhand:latest`            | 3000    | Docker container mgmt UI       |

To add a stack: extend `docker_stacks` with a new `compose_dir` and inline
`compose_file`. Ansible will `docker compose up -d` on each apply.

### Virtual machines (VirtualBox)

Declared in `host_vars/tav-serv.yml` under `vbox_vms`. Currently:

| Name  | RAM     | vCPUs | Firmware | Network            | VDI                                              |
|-------|---------|-------|----------|--------------------|--------------------------------------------------|
| haos  | 8192 MB | 4     | efi      | bridged on `eno3`  | `~/VirtualBox/haos/haos_ova-18.1.vdi`            |

VMs are only **created** if missing — the role does not touch existing VMs on
subsequent runs. This is intentional: post-creation edits should be explicit.

### Systemd services enabled

Managed via package installation + role tasks:

- `cockpit.socket` — web management UI on 9090
- `smartd` — SMART monitoring for megaraid disks
- `docker.service` + `containerd.service` — container runtime
- `libvirtd.service` — KVM guest manager
- `tailscaled.service` — Tailscale daemon

### Users, groups, and sudo

- User `tavaresm1` is added to groups: `docker`, `libvirt`, `kvm`, `vboxusers`
- **NOPASSWD sudo** grant lives at `/etc/sudoers.d/90-tavaresm1-nopasswd` —
  applied by hand once during rebuild (see runbook)
- `~/.ssh/authorized_keys` for `tavaresm1` is managed by `roles/user_env` from
  `roles/user_env/files/authorized_keys` — drop pubkeys there

### Kernel / sysctl

Set via `sysctl_settings` in `host_vars/tav-serv.yml`:

- `net.ipv4.ip_forward = 1` (Tailscale subnet routing)
- `net.ipv6.conf.all.forwarding = 1`
- `vm.swappiness = 10` (VM host tuning)

### Swap

Managed to `swapfile_size_mb: 8192` (8 GB) at `/swapfile`.

### Tailscale

- `tailscale up --ssh --advertise-routes=192.168.0.0/24 --accept-routes`
- Subnet route `192.168.0.0/24` needs approval in the Tailscale admin console
  after first apply (this is a one-time UI action, not automatable via CLI
  from the node itself)

---

## Rebuild runbook (Tav-Serv from scratch)

Order matters. Do these steps in sequence when reinstalling the OS (e.g. after
the SSD swap).

### 1. Install Linux Mint 22.3 (Cinnamon) from USB

- Set hostname: `Tav-Serv`
- Create user: `tavaresm1`
- Enable auto-login (optional — Ansible doesn't touch this)
- Install ssh: `sudo apt install -y openssh-server`

### 2. Verify baseline connectivity

From your workstation:

```bash
ssh tavaresm1@tav-serv "uname -a && lsb_release -a"
```

### 3. One-time manual bootstrap on Tav-Serv

These items cannot be done by Ansible because Ansible needs them to exist first.

```bash
# NOPASSWD sudo grant
echo 'tavaresm1 ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-tavaresm1-nopasswd
sudo chmod 440 /etc/sudoers.d/90-tavaresm1-nopasswd

# Drop the control node's SSH pubkey into authorized_keys
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# (paste the pubkey into ~/.ssh/authorized_keys, then:)
chmod 600 ~/.ssh/authorized_keys

# python3 is already in Mint 22.3 by default; verify:
which python3
```

### 4. iDRAC — verify or reconfigure (optional but recommended)

```bash
sudo ipmitool lan print 1                     # confirm 192.168.0.120 still set
sudo ipmitool user set password 2 <newpass>   # change from default calvin
sudo ipmitool sel clear                       # baseline event log
```

Add `Host tav-serv-idrac` block to `~/.ssh/config` on the workstation if you
want an easy alias.

### 5. Apply from the control node

```bash
cd Tav_Lab/ansible
ansible -i inventory/hosts.ini all -m ping         # must succeed
ansible-playbook -i inventory/hosts.ini site.yml --check --diff    # sanity
ansible-playbook -i inventory/hosts.ini site.yml                   # apply
```

Expect the first run to take 10–20 minutes (Docker + libvirt + VirtualBox
install pulls a lot of packages).

### 6. Post-apply verification

```bash
# On tav-serv:
docker ps -a
virsh list --all
VBoxManage list vms
tailscale status
systemctl is-enabled cockpit.socket smartd docker libvirtd tailscaled
```

Then browse:

- `https://tav-serv:9090` — Cockpit
- `http://tav-serv:3000` — Dockhand
- Tailscale admin console → approve `192.168.0.0/24` subnet route

### 7. Restore any data-only content

- HAOS VM data — if the VDI in `~/VirtualBox/haos/` is a fresh unzip, HAOS
  will onboard from scratch. If you're restoring an existing HAOS config,
  copy `.vdi` from backup into place before `--tags virtualization` runs.
- Docker volumes — restore `dockhand_data` from backup if the container had
  state worth preserving.

### 8. Optional post-first-run adjustments

- Fan control via `ipmitool raw 0x30 0x30 …` for noise reduction (not
  automated — investigate before applying)
- iDRAC Enterprise license (if you upgrade for virtual media / KVM)
- Bump BIOS to 6.6.0 via Dell DUP if you decide the risk is worth it

---

## Secrets

Sensitive values (e.g. Tailscale auth key for headless first-run, SMTP creds
for smartd alerts if you add them) live in `ansible/group_vars/all.vault.yml`,
encrypted with `ansible-vault`. The vault password itself is **not** in this
repo.

```bash
ansible-vault create ansible/group_vars/all.vault.yml
ansible-vault edit   ansible/group_vars/all.vault.yml
ansible-playbook ... --ask-vault-pass    # or --vault-password-file ~/.vault_pass
```

---

## What is NOT tracked here

Deliberately out of scope for this repo:

- **iDRAC config beyond password reset** — hardware BMC lives on its own
  lifecycle; not worth automating for a single node
- **BIOS updates** — do them by hand via Dell DUP or Lifecycle Controller
- **HAOS internal config** — that lives inside the VM, managed by Home Assistant
- **Guest OS state inside VMs** — Ansible provisions the shell; the guest is
  its own concern
- **Backups themselves** — this repo defines the box; a separate backup tool
  (rsync/borg to the QNAP over Tailscale) is a different problem
- **Ephemeral fixups** — anything you'd only do once during troubleshooting.
  If it needs to survive a rebuild, put it in a role

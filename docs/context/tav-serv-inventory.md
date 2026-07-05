# Tav-Serv software inventory (2026-07-05)

Snapshot of what's actually on the box, audited via `apt-mark showmanual`,
`docker ps`, `VBoxManage list vms`, and `systemctl list-unit-files`.
Every line item here should either be declared in the Ansible roles or
explicitly documented as out-of-scope.

## Base OS

- Linux Mint 22.3 Zena (Ubuntu 24.04 noble base)
- Kernel 6.17

## Post-install packages (25 hand-added)

Detected as the diff between `apt-mark showmanual` and the base installer's
initial package list.

### Base utilities
- htop
- bottom
- openssh-server

### Hardware / monitoring
- smartmontools
- ipmitool
- freeipmi-tools

### Containers (from `download.docker.com`)
- docker-ce
- docker-ce-cli
- containerd.io
- docker-buildx-plugin
- docker-compose-plugin

### Virtualization
- virtualbox
- virtualbox-ext-pack
- virtualbox-guest-utils
- (libvirt/qemu already present from Mint base or pulled in by cockpit-machines)

### Management UI
- cockpit
- cockpit-machines
- cockpit-pcp
  - Enables PCP daemons on ports 44321-44323 (pmcd/pmie/pmlogger/pmproxy)

### Network
- tailscale
- tailscale-archive-keyring

### Openbox/LXDE leftovers (should be purged)
- openbox
- obconf
- tint2
- lxappearance
- lxterminal
- pcmanfm

These came from an earlier install experiment and were deferred for cleanup
on 2026-07-05. They are listed in `ansible/group_vars/all.yml` under
`cleanup_packages`, so the base role will purge them on next apply.

## Third-party apt repositories

- `download.docker.com/linux/ubuntu` (noble stable) — Docker CE
- `pkgs.tailscale.com/stable/ubuntu` (noble main) — Tailscale

Both are re-declared in the Ansible `base` role, keyed by `/etc/apt/keyrings/docker.asc`
and `/usr/share/keyrings/tailscale-archive-keyring.gpg`.

## Running workloads

### Docker containers

| Name       | Image                                          | State       | Notes                                     |
|------------|------------------------------------------------|-------------|-------------------------------------------|
| dockhand   | `fnsys/dockhand:latest`                        | Up (healthy)| Web UI on `:3000`, socket mount           |
| sql2025    | `mcr.microsoft.com/mssql/server:2025-latest`   | Exited (137)| Likely OOM-killed; not currently declared |

Volumes: `dockhand_data`.

### VirtualBox VMs

| Name  | RAM     | vCPUs | Firmware | Network         | Notes                       |
|-------|---------|-------|----------|-----------------|-----------------------------|
| haos  | 8192 MB | 4     | EFI      | bridged on eno3 | HAOS 18.1, VRDE on port 3388 |

### libvirt VMs

None currently. A KVM guest was running on 2026-07-04 (on `vnet0`) but was
shut down so VirtualBox could hold the CPU virtualization extensions.
Note: VBox and KVM cannot run guests simultaneously on this host — pick one
per boot.

## Systemd services enabled (beyond base OS)

- `cockpit.socket` — port 9090
- `docker.service` + `containerd.service`
- `libvirtd.service`
- `smartd.service` (installed but config was empty until Ansible adds it)
- `tailscaled.service`

## Listening TCP ports observed

- 22 — SSH
- 53 — libvirt's dnsmasq on `virbr0` (192.168.122.1)
- 631 — CUPS (loopback only)
- 3000 — Dockhand
- 4330 — unidentified; investigate if it turns out to matter
- 9090 — Cockpit
- 44321-44323 — Cockpit-PCP daemons

## Users / groups

- `tavaresm1` — primary user
- Group memberships to reconcile (Ansible manages these): `docker`, `libvirt`,
  `kvm`, `vboxusers`
- **NOPASSWD sudo** grant at `/etc/sudoers.d/90-tavaresm1-nopasswd` is required
  by Ansible; must be added by hand once during rebuild (see repo README)

## Networking

- 4× Broadcom BCM5709 gigabit NICs: `eno1` (down), `eno2` (down), `eno3` (up,
  1000 Mbps full duplex), `eno4` (down)
- Bridges: `virbr0` (libvirt default 192.168.122.1/24), `docker0`
- Tailnet: `100.80.216.116` (`tav-serv` MagicDNS name)
- iDRAC: `192.168.0.120/24` on LAN, currently in shared LOM mode

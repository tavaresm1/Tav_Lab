# Tav_Lab

Tavares HomeLab — Infrastructure-as-code for **tav-serv**, a Dell PowerEdge R610
running **Proxmox VE 9** (Debian 13 trixie), and the guests on it.

Ansible runs from a container on the **`tavares-lab`** workstation and reaches
tav-serv over the tailnet. The hypervisor runs no Docker and no control plane of
its own — see [control-node/README.md](control-node/README.md) for why.

> **The box was Linux Mint + VirtualBox until the Proxmox rebuild.** The roles
> that configured it that way (`base`, `monitoring`, `virtualization`,
> `user_env`) have been retired, along with the dockhand stack and the
> VirtualBox HAOS VM. The reasoning is in
> [docs/context/design-decisions.md](docs/context/design-decisions.md); the code
> is in `git log`. The Mint-era software inventory is kept for reference in
> [docs/context/tav-serv-inventory.md](docs/context/tav-serv-inventory.md).

---

## What this repo manages

| Layer | Managed by | Notes |
|---|---|---|
| tav-serv host baseline | `roles/proxmox_host` | timezone, troubleshooting tools, sysctl, smartd for the PERC disks |
| tav-serv on the tailnet | `roles/tailscale` | subnet router for `192.168.1.0/24` |
| Ubuntu cloud-init template | `roles/proxmox_template` | VMID 8000, built once with `qm` |
| Autobase platform VMs | `roles/proxmox_guests` | 4 guests over the PVE API |
| Guest baseline | `roles/guest_baseline` | packages, hostnames, `/etc/hosts`, sudo, optional ufw |
| Autobase Console | `roles/docker` + `roles/autobase_console` | Docker CE + the upstream compose stack |
| PostgreSQL HA clusters | **Autobase itself** | Patroni/etcd/PgBouncer/vip-manager — not reinvented here |

PVE owns its own storage, networking, firewall and cluster configuration. This
repo deliberately does not touch those: second-guessing the hypervisor from
Ansible is how you lose a hypervisor.

Guests that predate this repo are **not** managed here. As of 2026-09-18 `qm list`
reports five:

| VMID | Name | Mem (MB) | Disk | State |
|---|---|---|---|---|
| 100 | `NAS` (TrueNAS SCALE) | 8048 | 32 GB | running |
| 101 | `Kieran-Craft` (Minecraft + BlueMap) | 16000 | 100 GB | running |
| 102 | `Tav-Assistant` | 8048 | 32 GB | running |
| 103 | `Hermes` | 18000 | 100 GB | running |
| 104 | `KCraft-b` | 8048 | 100 GB | stopped |

The Autobase platform uses 8000-8003 and 8010, so there is no VMID overlap.
`roles/proxmox_guests` still asserts that any VMID it is about to touch carries
the name it expects, so a collision stops the run instead of resizing someone
else's disk.

The memory column above is from before the 2026-09-18 trim. The box has **40 GB**
(`free -m` — not the 24 GB the docs claimed), and those four guests were
configured for 50 GB of it, leaving only ~9.2 GB available against the platform's
9728 MB. Guest memory was reduced to make room; the sizing note in
`inventory/group_vars/autobase.yml` has the arithmetic and the fallbacks.

---

## Repo layout

```
ansible/
  ansible.cfg                  Defaults (inventory, ssh args, become)
  requirements.yml             Pinned collections (incl. community.proxmox)
  inventory/
    hosts.ini                  Static inventory — tav-serv + the platform guests
    group_vars/                Beside the inventory, NOT beside site.yml — that
      all.yml                  is what makes the vars load for playbooks/*.yml
      all.vault.yml            (gitignored) ansible-vault secrets
      autobase.yml             THE file to edit for the Postgres platform
      autobase_guests.yml      Derived connection settings for the guests
      autobase_console.yml     Console-VM overrides
      pg_nodes.yml             DB-node overrides
    host_vars/
      tav-serv.yml             Hardware profile, sysctl, smartd devices
  site.yml                     Everything, in order
  playbooks/
    proxmox-host.yml           tav-serv baseline only
    autobase.yml               Template -> VMs -> guest baseline -> Console
    ping.yml                   Sanity: does Ansible reach the target
  roles/
    proxmox_host/              Hypervisor baseline (packages, sysctl, smartd)
    proxmox_template/          Ubuntu 24.04 cloud-init template via `qm`
    proxmox_guests/            VM clone/config/resize/start via the PVE API
    guest_baseline/            Inside-the-guest baseline
    docker/                    Docker CE + declarative compose stacks
    tailscale/                 Tailscale package + `up` flags + subnet routes
    autobase_console/          The Autobase Console stack
control-node/                  Containerized Ansible, runs on tavares-lab
aws/monitoring/                External monitoring node (CloudFormation)
docs/
  autobase.md                  Runbook for the Postgres platform
  hardware.md                  Physical inventory of the box
  context/                     Decisions, upgrades in flight, topology, workflow
```

---

## Quick start

Full bootstrap (keys, image build, first ping) is in
[control-node/README.md](control-node/README.md). Once that's done:

```bash
cd control-node

# Host baseline, dry-run then apply
docker compose run --rm ansible ansible-playbook playbooks/proxmox-host.yml --check --diff
docker compose run --rm ansible ansible-playbook playbooks/proxmox-host.yml

# The Postgres platform — read docs/autobase.md §1 first, it will refuse to run
# until the discovery values are confirmed
docker compose run --rm ansible ansible-playbook playbooks/autobase.yml --ask-vault-pass

# Everything
docker compose run --rm ansible ansible-playbook site.yml --ask-vault-pass
```

Tags: `proxmox_host`, `sysctl`, `smart`, `tailscale`, `tailscale-repo`, `net`,
`template`, `guests`, `baseline`, `firewall`, `console`, `docker`,
`docker-repo`, `stacks`.

---

## The Postgres platform

[Autobase](https://github.com/autobase-tech/autobase) builds Patroni-based
PostgreSQL HA clusters on machines you already own. It has no Proxmox provider,
so this repo provisions the machines and Autobase builds the clusters onto them.

```
autobase-console (VM 8010)  Ubuntu 24.04 · 2 vCPU · 2 GB · 32 GB · Docker CE
pgnode01-03    (VM 8001-3)  Ubuntu 24.04 · 2 vCPU · 2.5 GB · 40 GB each
                            Patroni · etcd · PostgreSQL · PgBouncer
                            vip-manager owns the cluster VIP
```

Guests run Ubuntu, not Rocky: the R610's X5670 is Westmere-EP with no AVX, so
the box is `x86-64-v2` and RHEL 10 (which needs `x86-64-v3`) cannot boot on it.

Three DB nodes on one physical host gives real Patroni failover and a real etcd
quorum, but **not** host-level HA — tav-serv is still a single point of failure.
That is exactly why the monitoring node lives in AWS
([aws/monitoring/README.md](aws/monitoring/README.md)).

Full runbook, failover drill and day-2 operations: [docs/autobase.md](docs/autobase.md).

---

## Tailscale

tav-serv is the tailnet subnet router for the lab LAN:

```
tailscale up --ssh --advertise-routes=192.168.1.0/24 --accept-routes
```

That is what makes iDRAC, the PVE UI (`https://tav-serv:8006`)
and the Autobase guests reachable from anywhere on the tailnet. The subnet route
needs **one-time approval in the Tailscale admin console** after first apply —
not automatable from the node.

The Autobase Console overrides these flags (`inventory/group_vars/autobase_console.yml`): a
guest has no business advertising the LAN subnet, and it publishes its UI with
`tailscale serve` instead of exposing `:80`.

Topology, MagicDNS caveats and the corporate-resolver failure mode:
[docs/context/tailscale-topology.md](docs/context/tailscale-topology.md).

---

## Secrets

Everything sensitive lives in `ansible/inventory/group_vars/all.vault.yml`, encrypted with
`ansible-vault` and gitignored. **This repo is public** — nothing secret goes in
plaintext, ever.

| Key | Used by |
|---|---|
| `vault_proxmox_api_token_secret` | `roles/proxmox_guests` (PVE API) |
| `vault_autobase_auth_token` | the Console's `.env` |
| `vault_tailscale_authkey` | non-interactive `tailscale up` on the guests |

```bash
ansible-vault create ansible/inventory/group_vars/all.vault.yml
ansible-vault edit   ansible/inventory/group_vars/all.vault.yml
ansible-playbook ... --ask-vault-pass    # or --vault-password-file ~/.vault_pass
```

---

## Rebuild runbook (tav-serv from scratch)

Order matters. The SSD swap in
[docs/context/upgrades-in-flight.md](docs/context/upgrades-in-flight.md) is the
likely reason to do this.

1. **Back up first** — to the QNAP over Tailscale. Guest disks (`vzdump` for
   TrueNAS VM 100 and the Minecraft guest), `/etc/pve`, and the host's `/etc`.
2. **Install Proxmox VE 9** from USB. Hostname `tav-serv`, static IP on the lab
   LAN, root password set. The installer handles partitioning and swap.
3. **Install the control pubkey** into `/root/.ssh/authorized_keys` — via the
   PVE web UI Shell at `https://tav-serv:8006`, or iDRAC if the network is down.
   (control-node/README.md step 3.)
4. **Verify reachability** from the workstation:
   ```bash
   ssh root@tav-serv 'pveversion; pvesm status; qm list'
   ```
5. **Apply the host baseline:**
   ```bash
   ansible-playbook playbooks/proxmox-host.yml --check --diff
   ansible-playbook playbooks/proxmox-host.yml
   ```
6. **Approve the subnet route** in the Tailscale admin console.
7. **Restore the pre-existing guests** from `vzdump` (TrueNAS, Minecraft).
8. **Rebuild the Postgres platform** — `docs/autobase.md`, start at §1. The
   template and VMs come back declaratively; the clusters get recreated from the
   Console.
9. **iDRAC check** (optional):
   ```bash
   ipmitool lan print 1                     # record the real iDRAC address
   ipmitool sel clear                       # baseline the event log
   ```

---

## What is NOT tracked here

- **PVE's own configuration** — storage, bridges, cluster, firewall. PVE owns it.
- **Pre-existing guests** — VMIDs 100-104, tabled above. TrueNAS especially:
  it's an appliance, hand-installed packages don't survive its upgrades.
- **PostgreSQL cluster internals** — Autobase's job, via the Console or the
  `vitabaks.autobase` collection.
- **iDRAC config beyond a password reset** — hardware BMC has its own lifecycle.
- **BIOS updates** — by hand via Dell DUP or Lifecycle Controller.
- **Guest OS state beyond the baseline** — the VM shell is provisioned here;
  what runs inside is that guest's own concern.
- **Backups themselves** — this repo defines the boxes; a separate tool
  (`vzdump` + rsync/borg to the QNAP over Tailscale) moves the data.
- **Ephemeral fixups** — if it needs to survive a rebuild, it goes in a role.

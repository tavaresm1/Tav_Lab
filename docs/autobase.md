# Autobase — self-hosted Postgres HA platform on tav-serv

[Autobase](https://github.com/autobase-tech/autobase) (formerly
`vitabaks/postgresql_cluster`) gives you a DBaaS-style web console that builds
Patroni-based PostgreSQL HA clusters on machines you own. This repo provisions
the machines; Autobase builds the clusters onto them.

**The split matters.** Autobase has no Proxmox provider — its cloud integrations
are AWS/GCP/Azure/DigitalOcean/Hetzner only. For Proxmox you use its
*"Your Own Machines"* path, which expects the VMs to already exist. So:

| Concern | Owner |
|---|---|
| Ubuntu 24.04 cloud-init template, 4 VMs, addressing, sudo, SSH keys | this repo (`playbooks/autobase.yml`) |
| PostgreSQL, Patroni, etcd, PgBouncer, vip-manager, failover, backups | Autobase |

## Architecture

```
                 tailnet
                    │
      ┌─────────────▼──────────────┐
      │ autobase-console (VM 8010) │  Ubuntu 24.04 · 2 vCPU · 2 GB · 32 GB
      │  console_ui  :80           │  Docker CE + 4-service compose stack
      │  console_api :8080         │  spawns autobase/automation containers
      │  console_db  (postgres)    │  tailscale serve → https://autobase
      │  dbdesk-studio :9876       │
      └─────────────┬──────────────┘
                    │ Ansible over SSH  (same L2 — required)
     ┌──────────────┼──────────────┐
     ▼              ▼              ▼
 pgnode01       pgnode02       pgnode03          VM 8001-8003
 Ubuntu 24.04 · 2 vCPU · 2.5 GB · 40 GB each
 Patroni :8008 · etcd :2379/2380 · Postgres :5432 · PgBouncer :6432
     └──────────────┴──────────────┘
                    │
              vip-manager owns the cluster VIP
              clients → VIP:5432 (rw) · VIP:6432 (pooled)
```

The Console **must** sit on the same network as the DB nodes — its API reaches
them with Ansible directly, over SSH, using the key you give it.

etcd is co-located on the three DB nodes. Autobase requires **at least 3
servers** for the RAFT quorum; the Postgres cluster itself could run on two, but
the DCS cannot.

## 1. Step 0 — discovery (do this first)

Everything in the `FILL IN` block at the top of
[`../ansible/group_vars/autobase.yml`](../ansible/group_vars/autobase.yml) starts
as a placeholder inferred from the documented lab LAN. The playbook refuses to run
until you have confirmed them and flipped `autobase_preflight_confirmed: true`.

```bash
ssh root@tav-serv '
  pvecm status 2>&1 | head -5     # single node, or a real cluster?
  free -m; nproc
  pvesm status                    # storage IDs + free space (need ~180 GB)
  qm list; pct list               # VM and CT IDs share ONE namespace
  ip -br addr
  grep -E "iface|address|gateway" /etc/network/interfaces
'
```

Then choose, from outside the DHCP pool: **4 static IPs** for the guests and
**1 unused IP** for the cluster VIP.

If `pvecm status` shows a real multi-node cluster, give each `pgnode` a
different `pve_node` — three "HA" nodes on one box survive a Postgres failure
but not a host failure.

## 2. Credentials

**Proxmox API token** (used by `community.proxmox.proxmox_kvm`):

```bash
ssh root@tav-serv '
  pveum user add ansible@pve
  pveum aclmod / -user ansible@pve -role PVEVMAdmin
  pveum aclmod /storage -user ansible@pve -role PVEDatastoreUser
  pveum user token add ansible@pve automation --privsep 0
'
```

Copy the printed secret. If a task later returns 403, widen the ACL rather than
guessing — `PVEVMAdmin` covers clone/config/start but not every storage action.

**SSH keys** — two, for two trust paths:

```bash
cd control-node
ssh-keygen -t ed25519 -f ./ssh_keys/ansible_control -C "ansible-control@tavares-lab"  # → root@tav-serv
ssh-keygen -t ed25519 -f ./ssh_keys/autobase        -C "autobase@tavares-lab"  # → ansible@guests
ssh-copy-id -i ./ssh_keys/ansible_control.pub root@tav-serv
```

Paste `ssh_keys/autobase.pub` into `autobase_ssh_pubkey` in
`group_vars/autobase.yml`. cloud-init installs it on every guest, and it is the
same key you hand the Console in step 5.

**Secrets** into the vault (already gitignored, see the README):

```bash
ansible-vault edit ansible/group_vars/all.vault.yml
```

```yaml
vault_proxmox_api_token_secret: "<the token secret from pveum>"
vault_autobase_auth_token: "<a long random string — this is the Console login>"
vault_tailscale_authkey: "<tskey-auth-... for the console VM's unattended join>"
```

## 3. Run it

From a host **on the tailnet** (this is the current constraint — a workstation
off the tailnet cannot resolve `tav-serv`):

```bash
cd control-node
docker compose build          # context is the repo root; bakes in requirements.yml
docker compose run --rm ansible ansible -i inventory/hosts.ini proxmox -m ping
docker compose run --rm ansible ansible-playbook playbooks/autobase.yml --ask-vault-pass
```

Or directly on `tav-serv`, if you'd rather not involve the container.

Slices, once the first run is done:

```bash
ansible-playbook playbooks/autobase.yml --tags template   # template only
ansible-playbook playbooks/autobase.yml --tags guests     # clone/resize/start
ansible-playbook playbooks/autobase.yml --tags baseline   # packages, hostnames, sudo
ansible-playbook playbooks/autobase.yml --tags console    # Docker + Tailscale + stack
```

The first run downloads a ~600 MB cloud image and builds the template; expect a few
minutes. Subsequent runs skip it — the template build is guarded on
`qm config 8000`.

## 4. Verify the guests

```bash
ssh root@tav-serv 'qm list'                 # 8000 template + 8001-8003 + 8010
ansible autobase_guests -m ping
ansible pg_nodes -a 'df -h /'          # ~40 GB — growpart ran, not the 3.5 GB image
ansible autobase_guests -a 'systemctl is-active qemu-guest-agent chrony'
```

If `df` shows the image's original size, cloud-init's `growpart` did not run —
the disk resize must happen *before* first boot, which is the order
`roles/proxmox_guests` uses. Re-running the `guests` tag after a manual resize
will not grow the filesystem; grow it in the guest with
`growpart /dev/sda 1 && resize2fs /dev/sda1` (the Ubuntu cloud image puts an
ext4 root on partition 1 — 14/15/16 are bios_grub, ESP and `/boot`).

## 5. Create the first cluster (Console UI)

Open `https://autobase` on the tailnet (or `http://<console-ip>/` on the LAN)
and sign in with `vault_autobase_auth_token`.

1. Deployment target → **Your Own Machines**
2. Enter the three `pgnode` IPs
3. Authentication → private key → paste `control-node/ssh_keys/autobase`
   (the **private** half), user `ansible`
4. **Cluster VIP** → your `autobase_cluster_vip`. Must be unused; the preflight
   already pinged it for you
5. Leave *HAProxy load balancer* **off** — we chose the vip-manager topology
6. Environment, cluster name, PostgreSQL version (17 or 18)
7. Review → **Create Cluster** (~10 minutes)

Watch **Operations → deploy → Show details** for the live Ansible log. If it
fails, that log is the first place to look, then
`journalctl -u patroni -u etcd` on the node that failed.

Connection details appear on the cluster page when it finishes.

### Expert mode

Settings → *Enable expert mode* unlocks what you'll actually want: DCS
placement, connection pool size and mode (**transaction** is the right default),
extensions, pgBackRest settings, and per-parameter Postgres tuning. There's also
a YAML tab (needs *Enable YAML editor* as well) for anything the forms don't
expose.

## 6. Prove it's actually HA

Creating a cluster is not the same as having failover. Test it:

```bash
ssh ansible@pgnode01 'sudo patronictl -c /etc/patroni/patroni.yml list'
#   one Leader, two Replicas, all streaming

ssh ansible@pgnode01 'sudo etcdctl endpoint health --cluster'   # 3/3 healthy

psql -h <VIP> -p 5432 -U postgres -c 'select pg_is_in_recovery()'   # f
psql -h <VIP> -p 6432 -U postgres -c 'select 1'                     # PgBouncer

# Failover drill — the whole point of the exercise
ssh ansible@pgnode01 'sudo patronictl -c /etc/patroni/patroni.yml switchover'
ping -c3 <VIP>                                                      # VIP moved
psql -h <VIP> -p 5432 -U postgres -c 'select inet_server_addr(), pg_is_in_recovery()'
#   new address, still not in recovery
```

Then connect pgAdmin 4 on the workstation to `<VIP>:5432` over the tailnet.

## Day 2: the Console won't do it, the collection will

The **Community Edition Console covers cluster creation only** — upstream is
explicit that it "does not include ongoing cluster management." Scaling, backups,
restores, switchovers and major-version upgrades through the UI are Enterprise
features.

The Ansible collection is MIT and does all of it for free. It is installed in
the control-node image via `ansible/requirements.yml`:

```bash
# Add a node, change config, take a backup — from the control node
ansible-playbook -i <autobase-inventory> vitabaks.autobase.config_pgcluster
ansible-playbook -i <autobase-inventory> vitabaks.autobase.add_pgnode
ansible-playbook -i <autobase-inventory> vitabaks.autobase.pg_upgrade
```

So: **UI to create, CLI for day 2.** Autobase writes its own inventory when the
Console deploys; for CLI work, keep one derived from
`automation/inventory.example` upstream, with `dcs_type: etcd` and
`with_haproxy_load_balancing: false` to match what we built.

## Things to know

- **The Console phones home** to `https://billing.autobase.tech` for signed
  entitlements. The console VM needs outbound HTTPS.
- **Three Postgres nodes on one physical host is not host-level HA.** You get
  genuine Patroni failover and a real etcd quorum to test against, but `tav-serv`
  stays a single point of failure — which is exactly why the monitoring node
  lives in AWS (`aws/monitoring/README.md`).
- **No host firewall by default.** `guest_firewall_enabled: false`, matching the
  rest of the repo — the LAN is the trust boundary. Flip it to `true` and
  `guest_baseline` configures ufw: SSH first, then 5432, 6432, 8008, 2379 and 2380
  restricted to `autobase_subnet_cidr`, then default-deny inbound. Add 5000-5003
  and 7000 to `autobase_cluster_ports` if you later turn on HAProxy.
- **Ubuntu, not Rocky.** Rocky 10 was the first choice and would not boot. RHEL 10
  requires an `x86-64-v3` CPU (AVX2/BMI2/FMA, Haswell and later); tav-serv is a
  single X5670 — Westmere-EP, 2010, no AVX at all — so it tops out at
  `x86-64-v2` and the kernel halts before reaching a console. Ubuntu 24.04 runs
  on `x86-64-v2`, and Autobase's CI covers it daily.
- **VMIDs share one namespace with containers.** `roles/proxmox_guests` asserts
  that any pre-existing VMID in `autobase_guests` carries the expected name, so
  a collision with TrueNAS (100) or the Minecraft guest stops the run instead of
  resizing someone else's disk.
- **The hypervisor's own baseline is a separate playbook.**
  `playbooks/proxmox-host.yml` handles tav-serv itself; this one handles the
  platform. `site.yml` imports both, in that order.

# Ansible control-node container

A small Alpine-based Docker image that runs Ansible against **tav-serv** (the
Dell R610, running Proxmox VE) and the Autobase guests on it, over SSH.

**Where it runs: the `tavares-lab` workstation.** Not on tav-serv, and this is a
decision rather than an accident:

- Docker CE on a Proxmox node rewrites iptables/nftables and manages its own
  bridges, which collides with PVE's firewall and `vmbr0`. The hypervisor keeps
  one job.
- The control node's first task is *building* the guests, so it cannot live in
  one of them.
- The workstation already has the repo checkout, the vault password, the SSH
  keys and tailnet reachability.

The image itself is still portable — any Docker host on the tailnet works
(laptop, WSL, another Linux box). If you later want day-2 `vitabaks.autobase`
runs that don't depend on the workstation being awake, the natural home is a
container on the `autobase-console` VM, which already runs Docker and already
holds SSH access to all three DB nodes.

---

## Prerequisites (the workstation)

`tavares-lab` is a **Linux Mint** box running **native Docker Engine** — that is
the configuration this is actually operated in, and the simplest one: host
networking works with no toggle, and the container's uid 1000 matches the host
user, so bind-mounted keys and vault files need no ownership fixing. The Docker
Desktop and PowerShell notes further down are portability notes, not the primary
path.

- **Docker Engine** 24+ (native on Linux; Docker Desktop on Windows/macOS also works)
- **`docker-compose`** — note the hyphen. Mint ships the v1 standalone binary,
  which is what these commands assume. (`docker compose`, the v2 plugin, is what
  runs *inside* the managed guests via `roles/docker` — both spellings are correct
  in this repo, in different places. Don't "fix" one to match the other.)
- **git**
- **Network access to tav-serv**, via Tailscale MagicDNS name `tav-serv`
- An OS user in the `docker` group

Tailscale must be up on the workstation and logged into the same tailnet as
tav-serv. The container inherits the host's Tailscale connection through
`network_mode: host` — see platform notes below.

> The inventory reaches tav-serv by **name**, not by Tailscale IP. The IP
> changed when the box was re-registered on the tailnet during the Proxmox
> rebuild, and MagicDNS makes it a non-issue.

---

## Bootstrap

### Step 1 — clone the repo on the workstation

```bash
git clone https://github.com/tavaresm1/Tav_Lab.git
cd Tav_Lab/control-node
```

Windows PowerShell:
```powershell
git clone https://github.com/tavaresm1/Tav_Lab.git
cd Tav_Lab\control-node
```

### Step 2 — generate two SSH keypairs

Two different trust paths, two keys, so either can be revoked alone:

| Key | Authorized on | Installed by |
|---|---|---|
| `ansible_control` | `root@tav-serv` | you, by hand, once (step 3) |
| `autobase` | `ansible@` every platform guest | cloud-init, from `autobase_ssh_pubkey` |

The container bind-mounts the whole `ssh_keys/` directory read-only and copies
what it finds into `~/.ssh` at mode `600` on every start.

**Do this before the first `docker-compose run`.** Compose silently creates an
empty directory at any bind-mount source that doesn't exist, so running out of
order leaves you with an empty `ssh_keys/` and a warning from the entrypoint
rather than working SSH.

Linux / macOS / WSL / Git Bash:
```bash
mkdir -p ssh_keys && chmod 700 ssh_keys
ssh-keygen -t ed25519 -f ssh_keys/ansible_control -N '' -C "ansible-control@tavares-lab"
ssh-keygen -t ed25519 -f ssh_keys/autobase        -N '' -C "autobase@tavares-lab"
```

Windows PowerShell:
```powershell
New-Item -ItemType Directory -Force ssh_keys | Out-Null
ssh-keygen -t ed25519 -f ssh_keys\ansible_control -N '""' -C "ansible-control@tavares-lab"
ssh-keygen -t ed25519 -f ssh_keys\autobase        -N '""' -C "autobase@tavares-lab"
```

Paste the contents of `ssh_keys/autobase.pub` into `autobase_ssh_pubkey` in
`ansible/inventory/group_vars/autobase.yml`. That is the key cloud-init installs on the
guests, and the same one you hand the Autobase Console when you create a
cluster. See [../docs/autobase.md](../docs/autobase.md).

### Step 2b — create the vault

**This is not optional, and it is not interchangeable with creating the vault in
your local checkout.** The container clones `Tav_Lab` from GitHub (see
`entrypoint.sh`), and `all.vault.yml` is gitignored because the repo is public —
so a vault file sitting in `ansible/inventory/group_vars/` on the workstation is
invisible inside the container. It has to go in `control-node/vault/`, which is
bind-mounted; the entrypoint copies it into the cloned repo on every start.

```bash
mkdir -p vault && chmod 700 vault
cat > vault/plain.yml <<'EOF'
vault_proxmox_api_token_secret: "<pveum user token add output>"
vault_autobase_auth_token: "<long random string — your Console login>"
vault_tailscale_authkey: "<tailscale admin console → Settings → Keys>"
EOF

# Prompts for a NEW vault password — remember it, every run needs it
docker-compose run --rm --entrypoint ansible-vault ansible \
    encrypt /home/ansible/vault/plain.yml --output /home/ansible/vault/all.vault.yml

rm -f vault/plain.yml        # do not skip this
```

The mount is read-write precisely so this works in place. To change a secret
later:

```bash
docker-compose run --rm --entrypoint ansible-vault ansible \
    edit /home/ansible/vault/all.vault.yml
```

| Variable | Used by | Required |
|---|---|---|
| `vault_proxmox_api_token_secret` | `roles/proxmox_guests` → PVE API | yes — preflight asserts it |
| `vault_autobase_auth_token` | Console `.env`; this is the UI login | yes — preflight asserts it |
| `vault_tailscale_authkey` | `roles/tailscale` on the console VM | only for `https://autobase` |

`control-node/vault/` is gitignored as a whole directory, so the plaintext
staging file above cannot be committed even if you forget to delete it.

### Step 3 — install the control pubkey on tav-serv

Get `ssh_keys/ansible_control.pub` appended to `/root/.ssh/authorized_keys` on
tav-serv. PVE logs in as root, so there is no sudo step and no second account.

**Preferred — from a machine that can already reach tav-serv:**
```bash
cat ssh_keys/ansible_control.pub | \
    ssh root@tav-serv 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

**If SSH isn't working yet:** use the PVE web UI at `https://tav-serv:8006` →
select the node → **Shell**. That is a root shell in the browser; paste the key
in there.

**If the box is unreachable on the network entirely:** iDRAC → virtual console →
log in as root → same paste. iDRAC is at **`192.168.1.251`** (static, confirmed
2026-09-19 — the old notes' `192.168.0.120` was wrong). Note that this is on the
LAN, so it is only reachable off-LAN once the tailnet subnet route is approved,
which is itself something this repo applies — don't count on it as the
break-glass path from outside the house.

### Step 4 — build the image

```bash
docker-compose build
```

Produces `tav_lab_ansible:latest`. The build context is the repo root so the
image can bake in `ansible/requirements.yml` — the collections (including
`community.proxmox` and `vitabaks.autobase`) are installed at build time, not
per-run.

### Step 5 — sanity check

```bash
docker-compose run --rm ansible \
    ssh -o StrictHostKeyChecking=accept-new root@tav-serv hostname
```

Expected output: `tav-serv`

Then the Ansible ping:

```bash
docker-compose run --rm ansible \
    ansible -i inventory/hosts.ini proxmox -m ping
```

Expected:
```
tav-serv | SUCCESS => { ... "ping": "pong" ... }
```

The guests will not answer until they exist — that's what the Autobase playbook
builds. Use `-m ping` against `proxmox` only until then.

If either fails, jump to **Troubleshooting**.

### Step 6 — apply

Host baseline first, dry-run:

```bash
docker-compose run --rm ansible \
    ansible-playbook playbooks/proxmox-host.yml --check --diff
```

Then the platform. Read [../docs/autobase.md](../docs/autobase.md) §1 first —
the playbook refuses to run until the Step 0 discovery values are confirmed:

```bash
docker-compose run --rm ansible \
    ansible-playbook playbooks/autobase.yml --ask-vault-pass
```

Everything at once (`site.yml` imports both):

```bash
docker-compose run --rm ansible \
    ansible-playbook site.yml --ask-vault-pass
```

Interactive shell inside the container:

```bash
docker-compose run --rm ansible bash
```

---

## Platform notes

### Linux, native Docker Engine — the actual setup

This is `tavares-lab` (Linux Mint) and it works as-is. `network_mode: host` gives
the container the host's Tailscale interface directly, with nothing to enable.
Two consequences worth knowing:

- The container runs as uid/gid 1000 (`ANSIBLE_UID`/`ANSIBLE_GID` in
  `docker-compose.yml`), which matches the first human user on a Mint install, so
  bind-mounted `ssh_keys/` and `vault/` are readable without ownership juggling.
  If your user is not uid 1000, `id -u` and adjust those build args.
- `docker-compose` here is the **v1 standalone** binary. Every command in this
  file is written for it.

The sections below are for moving the control node elsewhere. They are not
required reading for the primary setup.

### Windows — Docker Desktop

Docker Desktop 4.34+ supports host networking, but it's **opt-in**:

1. Docker Desktop → Settings → Resources → Network → tick **"Enable host
   networking"** → Apply & Restart
2. Ensure Tailscale is installed and up on Windows, so `tav-serv` resolves and
   routes from the host

If host networking is unavailable or you'd rather not enable it, comment out
`network_mode: host` in `docker-compose.yml`. The default bridge routes outbound
traffic through the host, so tailnet peers stay reachable — one extra NAT hop.

### WSL2

Works through Docker Desktop's WSL integration or a native Docker install inside
the distro. If Tailscale runs on the Windows side only, WSL2 traffic still
transits the host, so tav-serv is reachable. If Tailscale runs inside WSL, use
that instance directly.

### macOS — Docker Desktop

Same as Windows. Enable host networking, or accept the bridge fallback.
Tailscale must be installed on the Mac itself.

---

## Troubleshooting

**`ssh: connect to host tav-serv port 22: Connection timed out`**
- Tailscale isn't up on the workstation, or the container isn't inheriting the
  host's Tailscale connection.
- Verify `tailscale status` on the workstation lists tav-serv.
- On Docker Desktop: confirm host networking is enabled *and* Tailscale is
  running.
- Fallback: set `ansible_host` to tav-serv's LAN IP in `inventory/hosts.ini` if
  you're on the same LAN.

**`nslookup tav-serv` returns `Non-existent domain`**
- The workstation's DNS resolver flipped to the MathWorks corporate resolver
  (`10.90.12.16`) under a VPN state, displacing the MagicDNS override.
  Reconnect Tailscale. See `../docs/context/tailscale-topology.md`.

**`Permission denied (publickey)`**
- The step 3 pubkey never landed in `root@tav-serv:/root/.ssh/authorized_keys`.
- Isolate it from the host: `ssh -i ssh_keys/ansible_control root@tav-serv hostname`.
- PVE also ships `PermitRootLogin yes` with password auth — if key auth is the
  only thing failing, the file or its permissions are wrong (`700` on `~/.ssh`,
  `600` on `authorized_keys`).

**`Missing sudo password`**
- Shouldn't happen against tav-serv: the connection is already root. If you see
  it, the play is targeting a *guest*, where the `ansible` user's NOPASSWD grant
  comes from `roles/guest_baseline` — so run `--tags baseline` first.

**`ERROR! couldn't resolve module/action 'community.proxmox.proxmox_kvm'`**
- The image predates `ansible/requirements.yml` gaining that collection.
  `docker-compose build --no-cache`.

**Container can't clone the repo (`fatal: unable to access ...`)**
- Host has no internet, or `REPO_URL` is unreachable.
- For a fork or private repo, set `REPO_URL` in `docker-compose.yml` and mount a
  github.com SSH key, then adjust the entrypoint.

**`/home/ansible/Tav_Lab/.git: Permission denied` on clone**
- The `repo_cache` volume is root-owned. Docker creates a missing mountpoint as
  `root:root` and seeds a new named volume from the image path's ownership, so a
  volume created by an image that lacked `/home/ansible/Tav_Lab` stays root-owned
  while the container runs as uid 1000.
- Fix: `docker-compose build && docker volume rm control-node_repo_cache`. The
  image now pre-creates the mountpoints owned by `ansible`.

**`chmod: /home/ansible/.ssh/id_ed25519: Read-only file system`**
- Stale image. Keys used to be bind-mounted individually onto `~/.ssh`, where
  their mode came from the host and couldn't be corrected. The entrypoint now
  copies them out of the read-only mount instead. `docker-compose build`.

**`[FATAL tini (7)] exec /usr/local/bin/entrypoint.sh failed: Permission denied`**
- `entrypoint.sh` lost its exec bit. `COPY` preserves the source mode, and
  `core.fileMode=false` on a Windows checkout hides it from `git status`.
- Fixed in the image (`RUN chmod 0755`) and in the index (mode `100755`), so this
  only appears on a stale build: `git pull && docker-compose build`.

**Line-ending errors on `entrypoint.sh`** (`bad interpreter: /usr/bin/env`)
- Git converted LF → CRLF on Windows. `.gitattributes` pins shell scripts to LF,
  so a fresh clone should be clean. Otherwise:
  `git checkout --renormalize entrypoint.sh`.

---

## What lives where

```
control-node/
  Dockerfile             Alpine + Ansible + collections + git + openssh-client
  entrypoint.sh          Installs keys, clones/pulls Tav_Lab, then execs CMD
  docker-compose.yml     Host networking + ssh_keys mount + repo/ssh_state volumes
  ssh_keys/              (gitignored) ansible_control + autobase keypairs
```

`ssh_keys/` is **not** in the repo — each control-node host generates its own.
Different hosts can hold different pubkeys authorized on tav-serv, and any of
them can be revoked on its own by deleting the line from `authorized_keys`.

---

## Housekeeping

Force a fresh repo clone inside the container:
```bash
docker volume rm control-node_repo_cache
```

Rebuild after a Dockerfile or requirements change:
```bash
docker-compose build --no-cache
```

Remove everything the control node created on this host:
```bash
docker-compose down -v
docker image rm tav_lab_ansible:latest
```

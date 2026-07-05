# Ansible control-node container

A small Alpine-based Docker image that runs Ansible against Tav-Serv over SSH.

**This container is portable.** It runs on any machine with Docker and network
reachability to Tav-Serv (typically via Tailscale). Tav-Serv itself is *not*
special — you can run the control node from your workstation, a laptop, WSL,
another Linux box, or on Tav-Serv itself.

---

## Prerequisites (host machine)

- **Docker Engine** (Linux) or **Docker Desktop** (Windows/macOS), version 24+
- **git**
- **Network access to Tav-Serv**, usually via Tailscale (`100.80.216.116` or
  MagicDNS name `tav-serv`)
- An OS user with permission to run `docker` (member of the `docker` group on
  Linux, or Docker Desktop running under your login)

Optional but recommended:
- Tailscale up and logged into the same tailnet as Tav-Serv — the simplest way
  to make the container reach `100.80.216.116` is to inherit the host's
  Tailscale connection via host networking (see platform notes below)

---

## Bootstrap

### Step 1 — clone the repo on the control-node host

```bash
git clone https://github.com/tavaresm1/Tav_Lab.git
cd Tav_Lab/control-node
```

Windows PowerShell:
```powershell
git clone https://github.com/tavaresm1/Tav_Lab.git
cd Tav_Lab\control-node
```

### Step 2 — generate a dedicated SSH keypair for this control node

The container mounts these files read-only.

Linux / macOS / WSL / Git Bash:
```bash
mkdir -p ssh_keys && chmod 700 ssh_keys
ssh-keygen -t ed25519 -f ssh_keys/ansible_control \
           -N '' -C "ansible-control@$(hostname)"
```

Windows PowerShell:
```powershell
New-Item -ItemType Directory -Force ssh_keys | Out-Null
ssh-keygen -t ed25519 -f ssh_keys\ansible_control -N '""' -C "ansible-control@$env:COMPUTERNAME"
```

Two files land in `ssh_keys/`: the private key `ansible_control` and the
public key `ansible_control.pub`. **Only** the private key gets mounted into
the container. The `.pub` is what you install on Tav-Serv.

### Step 3 — install the pubkey on Tav-Serv

Whichever way is easiest, get the content of `ssh_keys/ansible_control.pub`
appended to `/home/tavaresm1/.ssh/authorized_keys` on Tav-Serv.

**Preferred — SSH from a machine that can already reach Tav-Serv:**
```bash
cat ssh_keys/ansible_control.pub | \
    ssh tavaresm1@tav-serv 'cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

**If you can only reach Tav-Serv from a different machine than this one:**
- Copy `ansible_control.pub` to that machine (email, scp, USB, whatever)
- On that machine, `cat ansible_control.pub >> ~/.ssh/authorized_keys` for
  the `tavaresm1` user

**If Tav-Serv is entirely unreachable** but you have iDRAC access at
`192.168.0.120`:
- Launch the virtual console
- Log in as `tavaresm1` locally
- Paste the pubkey contents into `~/.ssh/authorized_keys` by hand

**If you're bootstrapping Tav-Serv from a fresh install:**
- Same idea, but the file may not exist yet:
  ```bash
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  cat >> ~/.ssh/authorized_keys   # paste pubkey, Ctrl-D
  chmod 600 ~/.ssh/authorized_keys
  ```

### Step 4 — build the image

```bash
docker compose build
```

This produces `tav_lab_ansible:latest` locally. Takes ~2 minutes on first
build (Alpine + Ansible + collections).

### Step 5 — sanity check

Trust the SSH host key on first connection and confirm the container can
reach Tav-Serv:

```bash
docker compose run --rm ansible \
    ssh -o StrictHostKeyChecking=accept-new tavaresm1@100.80.216.116 hostname
```

Expected output: `Tav-Serv`

Then run the Ansible ping:

```bash
docker compose run --rm ansible \
    ansible -i inventory/hosts.ini all -m ping
```

Expected output:
```
tav-serv | SUCCESS => { ... "ping": "pong" ... }
```

If either fails, jump to **Troubleshooting** below.

### Step 6 — apply

Dry-run first to see what would change:

```bash
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml --check --diff
```

Then real apply:

```bash
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml
```

By tag:

```bash
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml --tags base
```

Interactive shell inside the container:

```bash
docker compose run --rm ansible bash
```

---

## Platform notes

### Linux (native Docker Engine)

Works as-is. `network_mode: host` in `docker-compose.yml` gives the container
direct access to the host's Tailscale interface, so `100.80.216.116` is
reachable without further plumbing.

### Windows — Docker Desktop

Docker Desktop 4.34+ supports host networking, but it's **opt-in**:

1. Docker Desktop → Settings → Resources → Network → tick **"Enable host
   networking"** → Apply & Restart
2. Ensure Tailscale is installed and up on Windows (so `100.80.216.116` is
   routable from the host)

If host networking is unavailable or you'd rather not enable it, edit
`docker-compose.yml`: comment out `network_mode: host` and the container
will use the default bridge network. Docker Desktop's default bridge routes
outbound traffic through the host, so Tailscale-connected IPs are still
reachable — just slightly slower and with an extra NAT hop.

### macOS — Docker Desktop

Same as Windows. Enable host networking in Docker Desktop settings, or
accept the bridge fallback. Tailscale must be installed on the Mac itself.

### WSL2

Works either through Docker Desktop's WSL integration or a native Docker
install inside the WSL distro. If Tailscale is running on the Windows side
only, WSL2 traffic still transits the host so Tav-Serv is reachable. If
Tailscale is running inside WSL, use that instance directly.

### Running the control node ON Tav-Serv itself

Legitimate for a homelab: run the container on Tav-Serv, targeting Tav-Serv
over SSH via `100.80.216.116` (Tailscale) or `127.0.0.1` (localhost).
Chicken-and-egg only matters if Tav-Serv itself is down, which is when the
control node is useless anyway — no target to manage.

---

## Troubleshooting

**`ssh: connect to host 100.80.216.116 port 22: Connection timed out`**
- Tailscale is not running on the host, or the container isn't inheriting
  the host's Tailscale connection.
- On Linux: verify `tailscale status` on the host shows Tav-Serv.
- On Docker Desktop: check that host networking is enabled *and*
  Tailscale is running.
- Fallback: swap `100.80.216.116` in `inventory/hosts.ini` for the LAN IP
  of Tav-Serv, if you have LAN reachability.

**`Permission denied (publickey)`**
- The pubkey from step 2 was never installed into
  `tavaresm1@tav-serv:~/.ssh/authorized_keys`.
- Test from the host directly:
  `ssh -i ssh_keys/ansible_control tavaresm1@100.80.216.116 hostname`
  and see if the same error appears — that isolates it to a key problem.

**`Missing sudo password` during playbook apply**
- Tav-Serv doesn't have the NOPASSWD sudo grant yet. On Tav-Serv, run:
  ```bash
  echo 'tavaresm1 ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-tavaresm1-nopasswd
  sudo chmod 440 /etc/sudoers.d/90-tavaresm1-nopasswd
  ```

**Container can't clone the repo (`fatal: unable to access ...`)**
- Host has no internet, or `REPO_URL` is unreachable.
- If cloning from a fork or private repo, set `REPO_URL` in
  `docker-compose.yml` and mount a github.com SSH key at
  `/home/ansible/.ssh/id_ed25519_github`, then adjust the entrypoint.

**`fatal: [tav-serv]: FAILED! => ... /usr/bin/python3 not found`**
- Tav-Serv is missing python3 — vanishingly rare on Mint 22.3, but fixable
  with `ssh tavaresm1@tav-serv "sudo apt install -y python3"`.

**Line-ending errors on `entrypoint.sh`** (`bad interpreter: /usr/bin/env`)
- Git converted LF → CRLF on Windows. `.gitattributes` in this repo pins
  shell scripts to LF, so a fresh clone should be clean. If yours isn't,
  re-clone or run `git checkout --renormalize entrypoint.sh`.

---

## What lives where

```
control-node/
  Dockerfile             Alpine + Ansible + git + openssh-client
  entrypoint.sh          Clones/pulls Tav_Lab on start, then execs CMD
  docker-compose.yml     Host networking + SSH key mount + repo cache
  ssh_keys/              (gitignored) Generated ed25519 keypair for Tav-Serv
```

The `ssh_keys/` directory is **not** in the repo — each control-node host
generates its own keypair. Different hosts can have different pubkeys
authorized on Tav-Serv, and any of them can be revoked independently by
removing the line from `authorized_keys`.

---

## Housekeeping

Force a fresh repo clone inside the container:
```bash
docker volume rm control-node_repo_cache
```

Rebuild the image after a Dockerfile change:
```bash
docker compose build --no-cache
```

Remove everything the control node created on this host:
```bash
docker compose down -v
docker image rm tav_lab_ansible:latest
```

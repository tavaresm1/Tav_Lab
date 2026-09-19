# Tailscale topology

Nodes on the shared tailnet. Updated for the Proxmox rebuild of tav-serv.

## Members

| Node               | Tailscale IP          | Role                                                     |
|--------------------|-----------------------|----------------------------------------------------------|
| `tav-serv`         | (re-assigned)         | Homelab hypervisor — Dell R610, Proxmox VE 9. Subnet router. |
| `tavares-lab`      | (assigned per-login)  | **Linux Mint** workstation, native Docker Engine. Ansible control node runs here. |
| `autobase`         | (assigned per-login)  | Autobase Console VM (8010). Publishes its UI via `tailscale serve`. |
| Friend's QNAP NAS  | (assigned per-login)  | External storage / backup target                         |

**Use MagicDNS names, not IPs.** tav-serv was `100.80.216.116` before the
Proxmox rebuild; re-registering the node changed it. Every inventory entry, doc
and script in this repo reaches hosts by name for exactly that reason — treat any
hard-coded tailnet IP you find as a bug.

The three `pgnode` guests are deliberately **not** on the tailnet. They are
reachable through tav-serv's subnet route, which keeps the DB nodes off the
tailnet ACL surface and means Autobase's own Ansible reaches them on plain L2 —
which is what it requires.

## Reach patterns

- **tavares-lab → tav-serv:** SSH as root via MagicDNS `tav-serv`. This is the
  path every ops command in this repo assumes, and the one the control-node
  container inherits through `network_mode: host`.
- **tavares-lab → PVE web UI:** `https://tav-serv:8006`.
- **Any tailnet peer → the lab LAN (`192.168.1.0/24`):** via tav-serv as subnet
  router. That is what makes iDRAC (address unconfirmed — see `docs/hardware.md`)
  and the platform guests reachable from off-LAN:
  ```
  tailscale up --ssh --advertise-routes=192.168.1.0/24 --accept-routes
  ```
  Set in `ansible/inventory/group_vars/all.yml` under `tailscale_up_flags`. The route needs
  **one-time approval in the Tailscale admin console** after first apply — that
  step cannot be automated from the node.

  > **None of these flags were actually set until 2026-09-19.** `tailscale debug
  > prefs` on the first real `proxmox_host` apply reported an empty
  > `AdvertiseRoutes`, `RouteAll: false` and `RunSSH: false`. tav-serv was on the
  > tailnet but was never a subnet router — this document described the intent, and
  > nothing had applied it. It went unnoticed because `ansible.builtin.command` is
  > skipped under `--check`, so dry runs said nothing about Tailscale at all; the
  > role now prints current prefs next to the desired flags for exactly this reason.
  > If off-LAN access to the lab ever seemed not to work, this was why.
- **Any tailnet peer → the Autobase Console:** `https://autobase`. The console VM
  overrides `tailscale_up_flags` in `inventory/group_vars/autobase_console.yml` — a guest
  has no business advertising the LAN subnet — and `tailscale serve --bg
  --https=443` fronts its `:80` rather than exposing it.
- **tav-serv, guests → the internet:** outbound only, for apt/Docker repos, the
  Ubuntu cloud image, and the Console's entitlement check against
  `https://billing.autobase.tech`.
- **tavares-lab → QNAP:** file sync target. Syncthing is the intended tool
  (installed both sides, folders shared over tailnet peer names). Still not
  configured.
- **AWS monitoring node → tav-serv:** the node in `aws/monitoring/` joins this
  tailnet to scrape the hypervisor from outside it, since three "HA" Postgres
  nodes on one box do not survive the box.

## Github Enterprise

`github.mathworks.com` is separate from the personal `github.com`. MathWorks
enterprise repos never carry personal homelab code; personal repos never
carry MathWorks work. Each has its own SSH key:

- `~/.ssh/id_ed25519_mathworks` — MathWorks enterprise github
- `~/.ssh/tav_lab` (or similar) — personal github.com

Both configured via `~/.ssh/config` `Host` blocks with `IdentityFile` +
`IdentitiesOnly yes` to prevent key leakage across hosts.

These are distinct from the two keys the control node uses
(`ansible_control` → `root@tav-serv`, `autobase` → `ansible@` the guests); those
live under `control-node/ssh_keys/` and are gitignored.

## Known caveats

- **The corporate resolver displaces MagicDNS.** `tavares-lab`'s DNS resolver can
  flip to a MathWorks resolver (`10.90.12.16`) under some VPN states. Symptom:
  `nslookup tav-serv` returns `Non-existent domain` and SSH by hostname fails.
  Fix: reconnect Tailscale. Do **not** work around it by pinning the tailnet IP —
  it is no longer the documented one.
- **The control node inherits the host's tailnet reachability** via
  `network_mode: host`. On `tavares-lab` (Linux Mint, native Docker Engine) that
  works with no configuration. If the control node is ever moved to a Docker
  Desktop host, host networking is opt-in there (`Settings → Resources → Network →
  Enable host networking`); without it the bridge still routes out through the
  host, one NAT hop slower.
- **Subnet-route approval is not idempotent-by-Ansible.** A rebuild of tav-serv
  re-registers the node, which means re-approving the `192.168.1.0/24` route in
  the admin console. It is step 6 of the rebuild runbook in the top-level README.

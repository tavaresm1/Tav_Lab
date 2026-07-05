# Tailscale topology

Nodes on the shared tailnet as of 2026-07-05.

## Members

| Node                | Tailscale IP        | Role                                            |
|---------------------|---------------------|-------------------------------------------------|
| Tav-Serv            | `100.80.216.116`    | Homelab hypervisor (Linux Mint on R610)         |
| Windows workstation | (assigned per-login)| Primary user workstation                        |
| Friend's QNAP NAS   | (assigned per-login)| External storage / backup target                |

MagicDNS is enabled on the tailnet, so `tav-serv` resolves without needing
the raw IP.

## Reach patterns

- **Workstation → Tav-Serv:** SSH via `tav-serv` (MagicDNS) or
  `100.80.216.116`. Every ops command in this repo assumes this path.
- **Tav-Serv → github.com:** outbound only, for the Ansible role to
  install packages and for the control-node container to clone the repo.
- **Windows workstation → QNAP:** file sync target. Syncthing is the
  intended tool (installed on both sides, folders shared over the tailnet
  peer hostnames). Not yet configured as of 2026-07-05.
- **Any tailnet peer → iDRAC (`192.168.0.120`):** requires the Tav-Serv
  role to advertise the LAN subnet:
  ```
  tailscale up --advertise-routes=192.168.0.0/24 --accept-routes --ssh
  ```
  Plus admin console approval of the subnet route. This is captured in
  `ansible/group_vars/all.yml` under `tailscale_up_flags`.

## Github Enterprise

`github.mathworks.com` is separate from the personal `github.com`. MathWorks
enterprise repos never carry personal homelab code; personal repos never
carry MathWorks work. Each has its own SSH key:

- `~/.ssh/id_ed25519_mathworks` — MathWorks enterprise github
- `~/.ssh/tav_lab` (or similar) — personal github.com

Both configured via `~/.ssh/config` `Host` blocks with `IdentityFile` +
`IdentitiesOnly yes` to prevent key leakage across hosts.

## Known caveats

- The Windows workstation's DNS resolver can flip to a MathWorks corporate
  resolver (`10.90.12.16`) under some VPN states, which displaces the
  MagicDNS override. Symptom: `nslookup tav-serv` returns `Non-existent
  domain` and SSH by hostname fails. Fixes: reconnect Tailscale, or use
  the raw `100.80.216.116` IP.
- Tailscale on Docker Desktop for Windows requires host networking to be
  enabled if the container needs to inherit the host's tailnet reachability
  (`Settings → Resources → Network → Enable host networking`).

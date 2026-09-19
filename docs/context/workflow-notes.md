# Workflow notes

Working conventions for anyone (including future-you) picking up this repo.

## Change flow

1. Everything this repo owns goes through the repo — no hand-tweaks on tav-serv.
   If you catch yourself editing something on the box directly, either
   revert it or codify it in a role.

   **The exception, and it's deliberate:** PVE's own configuration — storage,
   bridges, cluster membership, its firewall — is managed in the PVE UI and *not*
   tracked here. Changing `/etc/pve` or `/etc/network/interfaces` by hand is the
   correct move; it just means the values in `group_vars/autobase.yml`
   (`pve_storage`, `pve_bridge`, the subnet) need to follow.
2. Edit the role, group_vars, or host_vars in the repo.
3. Push to `origin/main` (or use a feature branch and PR-review yourself).
4. On the control-node host: `docker volume rm control-node_repo_cache`
   (force fresh clone), then re-run the playbook.
5. Always dry-run first: `--check --diff`.
6. Apply for real.
7. Verify with a task-specific spot-check — `systemctl status`, `qm list` /
   `qm config <vmid>` on tav-serv, `docker ps` on the console VM.

## When Ansible would touch something you don't want touched

Use tags to scope apply narrowly:

```bash
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml \
    --tags template,guests --check --diff
```

Or `--skip-tags` for the inverse. Available tags: `proxmox_host`, `sysctl`,
`smart`, `tailscale`, `tailscale-repo`, `net`, `template`, `guests`, `baseline`,
`firewall`, `console`, `docker`, `docker-repo`, `stacks`.

`--check` is less useful on the guest-building plays than elsewhere: the
clone/resize/start tasks are API calls whose results later tasks read back, so a
dry run of `playbooks/autobase.yml` against VMs that don't exist yet will report
skips and failures that a real run wouldn't. Dry-run the host baseline; just run
the platform play.

## Verifying drift

`--check --diff` is the honest answer to "what would Ansible do to my
box?". Run it before every real apply. If the diff shows unexpected
changes, either the box drifted or the code drifted — figure out which
before applying.

## Secrets

`ansible/group_vars/all.vault.yml` is the only place plaintext-sensitive
values should live, and it's encrypted. The vault password itself is
**never** in the repo — either type it with `--ask-vault-pass` or store
it at `~/.vault_pass` outside the repo and pass with `--vault-password-file`.

Never commit:
- Vault password files
- Anything under `control-node/ssh_keys/` (per-host SSH private keys)
- Tailscale auth keys (use vault)
- SMTP or webhook credentials for smartd alerts (use vault)

The `.gitignore` catches the common cases. `git status` before any commit
to spot new files that shouldn't be there.

## When network access to tav-serv is lost mid-session

Diagnose first, don't retry blindly. Likely causes:

- **Tailscale down or paused** on the client — `tailscale status` on the
  host that lost reach.
- **DNS resolver flipped** to a corporate one that doesn't know about
  MagicDNS — `nslookup tav-serv`. Reconnect Tailscale rather than substituting a
  tailnet IP; tav-serv's changed when it was re-registered during the Proxmox
  rebuild, so any IP written down anywhere is stale. `tailscale status` prints the
  current one if you genuinely need it.
- **VPN interference** — some corporate VPN clients grab all `100.x.x.x`
  traffic and redirect it. Try disabling the VPN or split-tunneling.
- **Subnet route unapproved** — if tav-serv answers but `192.168.1.x` addresses
  (iDRAC, the guests) don't, the `192.168.1.0/24` route needs approval in the
  Tailscale admin console. A node rebuild drops the old approval.
- **tav-serv actually down** — check iDRAC (address unconfirmed, see
  `docs/hardware.md`) from a LAN-connected device. If PVE is up but a guest
  isn't, the PVE UI at
  `https://tav-serv:8006` → the node → Shell gets you `qm` without SSH.

Do not:
- Retry the same failed SSH four times hoping DNS unstuck itself.
- Restart random services on tav-serv "just in case" — you can't reach it.

## Break checklist

Before stopping mid-work:

1. **Commit** anything uncommitted, even WIP — mark it `WIP:` in the
   commit message.
2. **Push** if you have remote access. If you don't, note it in the
   handoff so future-you knows to push before running the container
   entrypoint (which pulls from origin).
3. **Save context to memory files** (for the LLM operator) — hardware
   state, decisions made, files created, pending work, blockers. Not
   just a one-line summary; structured enough that a future session
   can pick up cold.
4. **Note blockers explicitly** — "control-node pubkey not yet on tav-serv"
   vs. "everything is applied and verified" is a huge difference to walk
   back into.

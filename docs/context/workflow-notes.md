# Workflow notes

Working conventions for anyone (including future-you) picking up this repo.

## Change flow

1. All changes go through the Ansible repo — no hand-tweaks on Tav-Serv.
   If you catch yourself editing something on the box directly, either
   revert it or codify it in a role.
2. Edit the role, group_vars, or host_vars in the repo.
3. Push to `origin/main` (or use a feature branch and PR-review yourself).
4. On the control-node host: `docker volume rm control-node_repo_cache`
   (force fresh clone), then re-run the playbook.
5. Always dry-run first: `--check --diff`.
6. Apply for real.
7. Verify with a task-specific spot-check on Tav-Serv (systemd unit status,
   `docker ps`, `VBoxManage list vms`, etc.).

## When Ansible would touch something you don't want touched

Use tags to scope apply narrowly:

```bash
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml \
    --tags docker,stacks --check --diff
```

Or `--skip-tags` for the inverse. Available tags: `base`, `cleanup`,
`sysctl`, `swap`, `unattended`, `cockpit`, `smart`, `docker`, `stacks`,
`virtualization`, `libvirt`, `vbox`, `vms`, `tailscale`, `net`, `user_env`,
`ssh`, `tmux`.

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

## When network access to Tav-Serv is lost mid-session

Diagnose first, don't retry blindly. Likely causes:

- **Tailscale down or paused** on the client — `tailscale status` on the
  host that lost reach.
- **DNS resolver flipped** to a corporate one that doesn't know about
  MagicDNS — `nslookup tav-serv`, then fall back to raw `100.80.216.116`.
- **VPN interference** — some corporate VPN clients grab all `100.x.x.x`
  traffic and redirect it. Try disabling the VPN or split-tunneling.
- **Tav-Serv actually down** — check iDRAC at `192.168.0.120` from a
  LAN-connected device (or over the advertised Tailscale subnet route).

Do not:
- Retry the same failed SSH four times hoping DNS unstuck itself.
- Restart random services on Tav-Serv "just in case" — you can't reach it.

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
4. **Note blockers explicitly** — "control-node bootstrap on Tav-Serv
   still needed" vs. "everything is applied and verified" is a huge
   difference to walk back into.

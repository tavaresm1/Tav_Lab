# Ansible control-node container

A small Alpine-based Docker image that runs Ansible against Tav-Serv over SSH.

## Bootstrap (one-time, on Tav-Serv)

```bash
# 1. Get the compose file + Dockerfile onto Tav-Serv
cd ~
git clone https://github.com/tavaresm1/Tav_Lab.git
cd Tav_Lab/control-node

# 2. Generate a dedicated SSH keypair for the control node
mkdir -p ssh_keys && chmod 700 ssh_keys
ssh-keygen -t ed25519 -f ssh_keys/ansible_control \
           -N '' -C 'ansible-control@tav-serv'

# 3. Authorize the pubkey against tavaresm1 on tav-serv itself
cat ssh_keys/ansible_control.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 4. Build the image
docker compose build
```

## Sanity check

```bash
# Trust the SSH host key on first run (or set StrictHostKeyChecking=accept-new)
docker compose run --rm ansible \
    ssh -o StrictHostKeyChecking=accept-new tavaresm1@100.80.216.116 hostname

# Ansible ping
docker compose run --rm ansible \
    ansible -i inventory/hosts.ini all -m ping
```

## Apply

```bash
docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml --check --diff

docker compose run --rm ansible \
    ansible-playbook -i inventory/hosts.ini site.yml
```

## Notes

- The container uses `network_mode: host` so it can reach `100.80.216.116`
  (Tailscale) or any host network directly. If you'd rather have proper
  network isolation, drop `network_mode` and connect via
  `ansible_host=host.docker.internal` (Docker maps this to the host).
- The repo is cloned into a named volume `repo_cache` so it persists between
  runs. To force a fresh clone: `docker volume rm control-node_repo_cache`.
- To edit the playbooks while iterating, either commit + push + rerun, or
  bind-mount the local repo checkout over `/home/ansible/Tav_Lab` — the
  entrypoint tolerates either.

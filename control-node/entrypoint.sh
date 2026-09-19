#!/usr/bin/env bash
# Entrypoint for the Tav_Lab Ansible control-node container.
# Clones the repo on first run, pulls on subsequent runs, then execs the CMD.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/tavaresm1/Tav_Lab.git}"
REPO_DIR="${REPO_DIR:-/home/ansible/Tav_Lab}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# SSH keys are mounted read-only by docker-compose:
#   id_ed25519 -> root@tav-serv (the Proxmox host)
#   autobase   -> ansible@ the Ubuntu guests
# Fix permissions defensively; the chmod is a no-op on a read-only mount, in
# which case the key must already be 600 on the host.
for key in id_ed25519 autobase; do
    if [[ -f "/home/ansible/.ssh/${key}" ]]; then
        chmod 600 "/home/ansible/.ssh/${key}" || true
    fi
done

if [[ ! -d "${REPO_DIR}/.git" ]]; then
    echo "[entrypoint] cloning ${REPO_URL} → ${REPO_DIR}"
    git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
else
    echo "[entrypoint] pulling ${REPO_BRANCH} in ${REPO_DIR}"
    git -C "${REPO_DIR}" fetch --quiet origin "${REPO_BRANCH}" || true
    git -C "${REPO_DIR}" checkout --quiet "${REPO_BRANCH}" || true
    git -C "${REPO_DIR}" pull --quiet --ff-only || true
fi

cd "${REPO_DIR}/ansible"
exec "$@"

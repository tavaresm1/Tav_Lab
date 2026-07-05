#!/usr/bin/env bash
# Entrypoint for the Tav_Lab Ansible control-node container.
# Clones the repo on first run, pulls on subsequent runs, then execs the CMD.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/tavaresm1/Tav_Lab.git}"
REPO_DIR="${REPO_DIR:-/home/ansible/Tav_Lab}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# SSH key for target (Tav-Serv) is expected at /home/ansible/.ssh/id_ed25519
# and mounted read-only by docker-compose. Fix permissions defensively.
if [[ -f /home/ansible/.ssh/id_ed25519 ]]; then
    chmod 600 /home/ansible/.ssh/id_ed25519 || true
fi

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

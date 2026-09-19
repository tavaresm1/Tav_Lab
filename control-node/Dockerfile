# Ansible control node for the homelab.
# Alpine base kept intentionally minimal — Ansible + SSH + git + a few utilities.
#
# Build context is the REPO ROOT (see docker-compose.yml) so that
# ansible/requirements.yml can be baked in:
#   docker compose build
FROM alpine:3.20

RUN apk add --no-cache \
        ansible \
        ansible-lint \
        py3-pip \
        py3-requests \
        openssh-client \
        git \
        bash \
        curl \
        jq \
        make \
        tini

# proxmoxer is what community.proxmox.proxmox_kvm / proxmox_disk talk to the
# PVE REST API through. Not packaged in Alpine, and it has to land in the system
# site-packages because Ansible modules run under the system interpreter —
# hence --break-system-packages rather than a venv.
RUN pip install --no-cache-dir --break-system-packages proxmoxer

# Collections go to a system-wide path, NOT root's home. Installing them as
# root put them in /root/.ansible/collections, which the unprivileged `ansible`
# user below could not see — so every FQCN outside ansible.builtin silently
# failed to resolve. /usr/share/ansible/collections is on the default search
# path for every user.
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections
COPY ansible/requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml \
        -p /usr/share/ansible/collections \
    && rm /tmp/requirements.yml

# Non-root user matches the host UID/GID passed at build time to avoid
# bind-mount permission grief.
ARG ANSIBLE_UID=1000
ARG ANSIBLE_GID=1000
RUN addgroup -g ${ANSIBLE_GID} ansible && \
    adduser -D -u ${ANSIBLE_UID} -G ansible -s /bin/bash ansible

USER ansible
WORKDIR /home/ansible

# Entrypoint clones the repo (or pulls if present) then execs the given command.
COPY --chown=ansible:ansible control-node/entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

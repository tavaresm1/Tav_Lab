# Ansible control node for Tav-Serv.
# Alpine base kept intentionally minimal — Ansible + SSH + git + a few utilities.
FROM alpine:3.20

RUN apk add --no-cache \
        ansible \
        ansible-lint \
        py3-pip \
        openssh-client \
        git \
        bash \
        curl \
        jq \
        make \
        tini

# Ansible collections used by the roles
RUN ansible-galaxy collection install \
        ansible.posix \
        community.general \
        community.docker

# Non-root user matches the host UID/GID passed at build time to avoid
# bind-mount permission grief.
ARG ANSIBLE_UID=1000
ARG ANSIBLE_GID=1000
RUN addgroup -g ${ANSIBLE_GID} ansible && \
    adduser -D -u ${ANSIBLE_UID} -G ansible -s /bin/bash ansible

USER ansible
WORKDIR /home/ansible

# Entrypoint clones the repo (or pulls if present) then execs the given command.
COPY --chown=ansible:ansible entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

#!/usr/bin/env bash
# Run on each home node (tav-serv, the Proxmox host, and inside each guest you
# care about). Installs the Netdata child + Grafana Alloy and points both at the
# monitoring node over the tailnet.
#
#   MON_HOST=mon-aws ND_KEY=<uuid> ./install-child.sh
#
# ND_KEY must match the value in SSM:
#   aws ssm get-parameter --name /monitoring/netdata-stream-key \
#     --with-decryption --query Parameter.Value --output text
#
# On the Proxmox host run this on the HYPERVISOR, not in a container -- that is
# where the ZFS, SMART and per-guest cgroup data lives.

set -euo pipefail

MON_HOST="${MON_HOST:-mon-aws}"
ND_KEY="${ND_KEY:?ND_KEY is required}"
SEND_LOGS="${SEND_LOGS:-yes}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- netdata child
if ! command -v netdata >/dev/null 2>&1; then
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry
fi

CONFDIR=/etc/netdata
[ -d /opt/netdata/etc/netdata ] && CONFDIR=/opt/netdata/etc/netdata

cat > "$CONFDIR/stream.conf" <<EOF
[stream]
    enabled = yes
    destination = ${MON_HOST}:19999
    api key = ${ND_KEY}
    timeout seconds = 60
    buffer size bytes = 10485760
    reconnect delay seconds = 5
EOF
chmod 640 "$CONFDIR/stream.conf"
chown root:netdata "$CONFDIR/stream.conf" 2>/dev/null || true

# Keep no local database -- the parent owns retention. Health is disabled locally
# so the parent is the single place alarms fire from.
cat > "$CONFDIR/netdata.conf" <<'EOF'
[db]
    mode = ram
    retention = 1200

[health]
    enabled = no

[web]
    mode = static-threaded
    bind to = 127.0.0.1
EOF

systemctl restart netdata

# ---------------------------------------------------------------- grafana alloy
if [ "$SEND_LOGS" = "yes" ]; then
  if ! command -v alloy >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update -y
    apt-get install -y alloy
  fi

  sed -e "s|__MON_HOST__|${MON_HOST}|g" \
    "$(dirname "$0")/config.alloy" > /etc/alloy/config.alloy

  # The packaged service runs as user 'alloy', which cannot read the journal
  # until it is in the systemd-journal group.
  usermod -aG systemd-journal alloy || true

  systemctl enable --now alloy
  systemctl restart alloy
fi

echo
echo "done. verify on the monitoring node:"
echo "  http://${MON_HOST}:19999   -- this host should appear in the node list"
echo "  http://${MON_HOST}:3000    -- Explore > Loki > {job=\"systemd-journal\"}"

# Tailnet monitoring node — deployment runbook

Builds an always-on **external** monitoring host in AWS, joined to your tailnet, that
watches the `pve` Proxmox node and its guests.

External on purpose: `pve` is now the only home hypervisor, so anything running *on*
`pve` cannot tell you when `pve` has died. That single fact drives the whole design.

```
                        tailnet (WireGuard)
  ┌───────────────┐                              ┌───────────────────────────────┐
  │ pve (Proxmox) │── netdata child ──── push ──▶│ mon-aws  (EC2 Graviton)        │
  │  ├ TrueNAS VM │── alloy (journal) ── push ──▶│   netdata parent      :19999   │
  │  └ kieran-    │                              │   uptime-kuma         :3001    │
  │     craft     │◀──── synthetic probes ───────│   ntfy                :8080    │
  └───────────────┘                              │   loki                :3100    │
  ┌───────────────┐                              │   grafana             :3000    │
  │ Windows / phone│──── browser / app ─────────▶│                               │
  └───────────────┘                              └───────────────────────────────┘
                                                  Security group: ZERO inbound rules
```

**Metrics and logs are pushed upward**, so the monitoring node never dials into your
home network. Only Uptime Kuma reaches in, and only to the ports you tell it to probe.

## Contents

| File | Purpose |
|---|---|
| `01-network.yaml` | Dual-stack VPC, one public subnet, IGW. No NAT gateway. |
| `02-monitoring.yaml` | IAM role, empty-ingress security group, EC2 instance, full bootstrap. |
| `deploy.sh` | `preflight` / `secrets` / `network` / `monitoring` / `all` / `status` / `destroy`. |
| `home-node/install-child.sh` | Run on each home node. Installs the Netdata child + Alloy. |
| `home-node/config.alloy` | Journal → Loki shipping config, templated by the script. |

## Two deployment sizes

| | `WatchdogOnly` | `FullStack` (recommended) |
|---|---|---|
| Runs | Netdata parent, Uptime Kuma, ntfy | + Loki, Grafana |
| Gives you | Metrics, alerts, uptime checks | + centralised logs |
| Instance | `t4g.nano` (0.5 GB) | `t4g.medium` (4 GB) |
| Data volume | 8 GB | 100 GB |
| **Cost/month** | **~$9** | **~$38** |

Cost breakdown for `FullStack`, us-east-1 on-demand — **verify current pricing, these
are estimates**:

| Line item | Cost |
|---|---|
| `t4g.medium` instance | $24.53 |
| gp3 storage: 100 GB data + 20 GB root, @ $0.08/GB | $9.60 |
| Public IPv4 address | $3.65 |
| Data transfer **in** (metrics + logs) | $0.00 — inbound is free |
| CloudWatch alarms, SNS email | ~$0.00 at this volume |
| | **$37.78** |

`WatchdogOnly` on a `t4g.nano`: $3.07 instance + $2.24 storage (8 GB data + the same
20 GB root) + $3.65 IPv4 = **$8.96**.

A 1-year no-upfront Savings Plan takes roughly 30% off the instance line. And read
"Is AWS the right place for this?" at the bottom before committing to the monthly bill.

---

# Part 1 — Prerequisites

I checked your workstation. **Four things are missing.** Steps 1.1–1.4 fix them.

## 1.1 AWS credentials (not configured)

`aws configure list` currently shows no profile, key, or region. Pick one:

```bash
# Option A: static keys for a personal account
aws configure
#   AWS Access Key ID:     ...
#   AWS Secret Access Key: ...
#   Default region name:   us-east-1
#   Default output format: json

# Option B: SSO / Identity Center (use this if it is a MathWorks account)
aws configure sso
export AWS_PROFILE=<profile-name>
```

Verify — this must print an ARN before you go further:

```bash
aws sts get-caller-identity
```

The deploying principal needs to create VPC, EC2, IAM roles, SSM parameters, SNS
topics, and CloudWatch alarms. If IAM creation is denied you cannot deploy this stack
as written.

## 1.2 Session Manager plugin (missing)

This is your **only** way onto the box if Tailscale fails to come up, because the
security group has no inbound rules and no SSH key exists. Install it before you
deploy, not after you need it.

Download and run the Windows installer:
<https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>

```bash
session-manager-plugin --version   # should print a version
```

## 1.3 Tailscale on this workstation (not detected)

I could not find `tailscale` on PATH or in `C:\Program Files\Tailscale\`. If it was
removed along with Tav-Serv, reinstall it — you need this workstation on the tailnet
to reach any of the monitoring UIs.

<https://tailscale.com/download/windows>

```bash
tailscale status    # your devices should be listed
```

Also install Tailscale on **your phone** if you want ntfy alerts there. See step 7.2
for the caveat about that.

## 1.4 `uuidgen` (missing from your git-bash)

Already handled — `deploy.sh` falls back to `python` or `powershell`, both of which
work here. Nothing to do; noted so the fallback isn't a surprise.

## 1.5 Run the preflight check

```bash
cd C:/Users/mtavares/git/Tav_Lab/aws/monitoring
chmod +x deploy.sh home-node/install-child.sh
./deploy.sh preflight
```

Expected:

```
== preflight
  ok    aws cli: aws-cli/2.35.13
  ok    credentials: arn:aws:iam::...:user/...
  ok    region: us-east-1
  ok    uuid source available (sample 8493a5fb...)
  ok    session-manager-plugin present (break-glass access works)
  todo  /monitoring/tailscale-authkey missing -- run './deploy.sh secrets'
  todo  /monitoring/netdata-stream-key missing -- run './deploy.sh secrets'
  preflight passed
```

The two `todo` lines are expected on a first run. Any `FAIL` line stops you here.

---

# Part 2 — Tailscale setup

Do this **before** deploying. The instance consumes an auth key during boot; if the
key is wrong or the tag is undefined, bootstrap fails and the stack rolls back.

## 2.1 Define the ACL tag

Open <https://login.tailscale.com/admin/acls>. You must define `tag:monitor` before
a key can carry it. Minimum working policy:

```jsonc
{
  "tagOwners": {
    "tag:monitor": ["autogroup:admin"]
  },
  "acls": [
    // you -> the monitoring UIs
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:monitor:3000,3001,8080,19999"]
    },
    // home nodes -> netdata parent + loki  (the push path)
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:monitor:3100,19999"]
    },
    // monitoring node -> home hosts, for synthetic probes ONLY.
    // Narrow this to specific hosts once you know what you are probing.
    {
      "action": "accept",
      "src": ["tag:monitor"],
      "dst": ["autogroup:member:8006,25565,8100,443,80"]
    }
  ],
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:monitor"],
      "users": ["root", "ubuntu"]
    }
  ]
}
```

Save. Tailscale validates it on save — fix any error before continuing.

## 2.2 Generate a tagged auth key

<https://login.tailscale.com/admin/settings/keys> → **Generate auth key**:

| Setting | Value | Why |
|---|---|---|
| Reusable | No | One-shot is enough; the node persists after joining. |
| Expiration | 90 days (of the *key*) | Only the key expires, not the node. |
| **Ephemeral** | **No** | Ephemeral nodes are removed when offline. Fatal here. |
| **Tags** | **`tag:monitor`** | **Required.** A tagged node's key never expires, so the node won't drop off the tailnet in 90 days. |

Copy the `tskey-auth-...` value. You paste it in the next step and never need it again.

---

# Part 3 — Deploy

## 3.1 Store the secrets

```bash
./deploy.sh secrets
```

Prompts for the Tailscale key (hidden input, validated for the `tskey-auth-` prefix)
and stores it as an SSM SecureString. It also generates the Netdata streaming key and
prints it — **copy that UUID**, every home node needs the identical value.

Neither secret is ever passed as a CloudFormation parameter, so they don't appear in
UserData, stack events, or `describe-stacks` output.

Retrieve the streaming key later with:

```bash
aws ssm get-parameter --name /monitoring/netdata-stream-key \
  --with-decryption --query Parameter.Value --output text
```

## 3.2 Deploy the network stack

```bash
./deploy.sh network
```

Takes about a minute. Creates a `10.30.0.0/16` VPC with one dual-stack public subnet.
If `10.30.0.0/16` collides with your home LAN, override it:

```bash
aws cloudformation deploy --stack-name mon-network --template-file 01-network.yaml \
  --parameter-overrides VpcCidr=10.77.0.0/16 SubnetCidr=10.77.1.0/24
```

## 3.3 Deploy the monitoring node

Recommended (full stack, with email alarms on the node's own health):

```bash
MODE=FullStack INSTANCE_TYPE=t4g.medium DATA_GB=100 \
  ALERT_EMAIL=you@example.com ./deploy.sh monitoring
```

Or the cheap watchdog:

```bash
MODE=WatchdogOnly INSTANCE_TYPE=t4g.nano DATA_GB=8 ./deploy.sh monitoring
```

**This takes 8–15 minutes** and the CLI blocks the whole time. The instance signals
CloudFormation when bootstrap finishes; the timeout is 25 minutes.

**On your first deploy, use the debug flag:**

```bash
DISABLE_ROLLBACK=1 MODE=FullStack ALERT_EMAIL=you@example.com ./deploy.sh monitoring
```

Without it, a bootstrap failure rolls the stack back and deletes the instance —
taking the log that explains the failure with it. With it, the instance survives for
inspection and you delete the stack by hand afterwards.

### Watching the bootstrap live

In a second terminal, once the instance exists:

```bash
INSTANCE=$(aws cloudformation describe-stack-resources --stack-name mon-node \
  --logical-resource-id MonitorInstance \
  --query 'StackResources[0].PhysicalResourceId' --output text)

aws ssm start-session --target "$INSTANCE"
sudo tail -f /var/log/monitoring-bootstrap.log
```

Bootstrap order: apt → AWS CLI v2 → fetch secrets from SSM → find/format/mount
`/data` → Docker + Tailscale → join tailnet → Netdata → generate Grafana password →
write compose files → `docker compose up -d` → signal CloudFormation.

## 3.4 Confirm

```bash
./deploy.sh status
```

`CREATE_COMPLETE` on both stacks, plus an outputs table with every URL, the Grafana
password command, and the break-glass command.

If you set `ALERT_EMAIL`, **check your inbox and confirm the SNS subscription** — an
unconfirmed subscription silently delivers nothing.

---

# Part 4 — Verify the node

Several commands below use `$INSTANCE`. In a fresh shell, set it first:

```bash
INSTANCE=$(aws cloudformation describe-stack-resources --stack-name mon-node \
  --logical-resource-id MonitorInstance \
  --query 'StackResources[0].PhysicalResourceId' --output text)
```

## 4.1 It joined the tailnet

```bash
tailscale status | grep mon-aws
```

Should show `mon-aws` with a `tag:monitor` tag. If it isn't there, the auth key was
wrong or the tag was undefined — see Troubleshooting.

## 4.2 Services are listening

```bash
aws ssm start-session --target "$INSTANCE"
sudo docker ps                        # uptime-kuma, ntfy, + loki/grafana on FullStack
sudo systemctl status netdata --no-pager
sudo ss -tlnp | grep -E '3000|3001|3100|8080|19999'
df -h /data                           # the data volume is mounted
```

Ports bind to the Tailscale address, not `0.0.0.0` — that's deliberate. Netdata on
`:19999` is the exception: it binds broadly because it can start before `tailscale0`
exists at boot, so the empty security group plus its `allow from` list are the
controls there.

## 4.3 The UIs load

From your workstation, on the tailnet:

- Netdata — <http://mon-aws:19999>
- Uptime Kuma — <http://mon-aws:3001>
- ntfy — <http://mon-aws:8080>
- Grafana — <http://mon-aws:3000> (FullStack only)

If MagicDNS isn't resolving `mon-aws`, use the tailnet IP from `tailscale status`.

---

# Part 5 — Onboard the home nodes

This is the half that actually produces data. Nothing appears in Netdata's node list
or Loki until you do this.

## 5.1 The Proxmox host — do this one first

Run on the **hypervisor itself**, not in a container. That's where the ZFS, SMART,
and per-guest cgroup metrics live, and Netdata resolves Proxmox VMIDs to guest names
from there — which is why this stack needs no `prometheus-pve-exporter`.

```bash
# from your workstation
ND_KEY=$(aws ssm get-parameter --name /monitoring/netdata-stream-key \
  --with-decryption --query Parameter.Value --output text)

scp home-node/install-child.sh home-node/config.alloy root@pve:/tmp/
ssh root@pve "cd /tmp && MON_HOST=mon-aws ND_KEY=$ND_KEY bash install-child.sh"
```

The script installs Netdata as a child (`memory mode = ram`, local health disabled so
alarms only fire once, from the parent) and Grafana Alloy to ship the journal to Loki.
It adds the `alloy` user to `systemd-journal`, without which Alloy silently reads
nothing.

Verify within about a minute:

```bash
ssh root@pve "systemctl status netdata alloy --no-pager | grep -E 'Active|●'"
```

Then check <http://mon-aws:19999> — `pve` should appear in the node list on the left.

## 5.2 Guest VMs and containers

Same command, per guest. Run it only where it earns its keep:

| Guest | Do this |
|---|---|
| `kieran-craft` (Minecraft) | Run the script. Debian/Ubuntu based, works as-is. |
| **TrueNAS SCALE (VM 100)** | **Do not run the script.** SCALE is an appliance — packages installed by hand don't survive upgrades. Monitor it with Uptime Kuma probes plus its own built-in reporting. Hypervisor-level CPU/RAM/disk still comes from `pve`. |
| LXC containers | The script works, but many collectors are limited inside a container. Often not worth it — the host's cgroup metrics already cover resource use. |

## 5.3 Confirm logs are arriving

<http://mon-aws:3000> → **Explore** → Loki datasource → run:

```
{job="systemd-journal"}
```

You should see entries labelled by `host`, `unit`, and `level`. If the query returns
nothing, check Alloy on the node: `journalctl -u alloy -n 50`.

---

# Part 6 — Configure Uptime Kuma

<http://mon-aws:3001>. **The first page creates the admin account** — do this
promptly; until you do, anyone on your tailnet who reaches it can claim it.

Add these monitors:

| Name | Type | Target | Notes |
|---|---|---|---|
| pve web UI | HTTP(s) | `https://pve:8006` | Turn **off** certificate validation (self-signed). |
| TrueNAS UI | HTTP(s) | `https://<truenas>` | Certificate validation off. |
| Minecraft | TCP Port | `pve` : `25565` | Port check, not HTTP. |
| BlueMap | HTTP(s) | `http://pve:8100` | |
| **Home heartbeat** | **Push** | — | **The important one. See below.** |

## 6.1 The heartbeat monitor — the alarm that matters most

Every monitor above tells you a *service* is down. The push monitor tells you the
*house* is down, which is the reason this node is in AWS at all.

Create a **Push** monitor, set the heartbeat interval to 120 seconds, and copy its
push URL. Then on the `pve` host:

```bash
ssh root@pve
cat >/etc/cron.d/uptime-heartbeat <<'EOF'
* * * * * root curl -fsS --max-time 20 "http://mon-aws:3001/api/push/<TOKEN>" >/dev/null 2>&1
EOF
systemctl restart cron
```

Substitute the real token. If `pve` dies, loses power, or your internet drops, the
pushes stop and Uptime Kuma alerts. Nothing running at home can do this for you.

## 6.2 Wire notifications

**Settings → Notifications → Setup Notification** → type **ntfy**:

- Server URL: `http://ntfy` — Uptime Kuma reaches ntfy over the Docker network by
  container name. Do not use `mon-aws` here; that hairpins out to the tailnet address
  unnecessarily.
- Topic: `alerts`
- Apply as default for all existing monitors.

Add your `ALERT_EMAIL` as a second notification channel too. Redundancy is the point.

**Two topics exist**, deliberately separated by source: Uptime Kuma publishes to
`alerts`, Netdata publishes to `netdata`. Subscribe to **both** in the ntfy app, or
change one of them to match if you would rather have a single stream.

---

# Part 7 — Alerting

## 7.1 Verify the Netdata → ntfy path

Netdata's bootstrap appends `SEND_NTFY="YES"` and points at the local ntfy container.
Test it end to end:

```bash
aws ssm start-session --target "$INSTANCE"
sudo -u netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test
```

**If this reports ntfy as an unknown method**, your Netdata build lacks ntfy support.
Fall back to Discord or Telegram — edit `/etc/netdata/health_alarm_notify.conf`:

```bash
SEND_DISCORD="YES"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
DEFAULT_RECIPIENT_DISCORD="alarms"
```

Then `sudo systemctl restart netdata` and re-run the test.

## 7.2 Getting alerts to your phone — read this before relying on it

Self-hosted ntfy on a tailnet works, with a real caveat: the Android/iOS app must
hold a persistent connection to your server, which costs battery and can be killed by
aggressive power management. There is no FCM/APNS push for self-hosted instances.

Your options, honestly ranked:

1. **Email via SNS** (`ALERT_EMAIL`) — dull, and the most reliable thing here. Keep it.
2. **Public ntfy.sh with a long random topic** — gets real push notifications. Trade-off:
   alert *titles* transit a third party. Set
   `DEFAULT_RECIPIENT_NTFY="https://ntfy.sh/mon-a8f3d2e1c7b9"` in
   `health_alarm_notify.conf`.
3. **Self-hosted ntfy over the tailnet** — private, but subject to the battery caveat.

Note the failure path holds up either way: an alert originates on the EC2 node, which
stays up when your house doesn't, and reaches your phone over cellular via Tailscale.

## 7.3 Expect to silence some defaults

Netdata's stock alarm set is good but chatty. Budget an evening trimming the usual
suspects in `/etc/netdata/health.d/`: `10min_disk_utilization`, inode warnings, TCP
retransmits. This is the tax for getting useful alerts on day one instead of week three.

---

# Part 8 — Grafana

FullStack only. <http://mon-aws:3000>, user `admin`:

```bash
aws ssm get-parameter --name /monitoring/grafana-admin-password \
  --with-decryption --query Parameter.Value --output text
```

The password is generated on the instance at first boot and written to SSM — it is
never in the template or in your shell history.

Loki is pre-provisioned as the default datasource. **Metrics are not in Grafana** —
use Netdata's own UI on `:19999`. Netdata's `allmetrics` endpoint is a Prometheus
*scrape target*, not a query API, so it cannot back a Grafana Prometheus datasource.
If you want PromQL and dashboards-as-code, add a real Prometheus that scrapes
`http://<tailnet-ip>:19999/api/v1/allmetrics?format=prometheus` and point Grafana at
that instead.

---

# Part 9 — Day-2 operations

**Change size or mode** — re-run with new values; CloudFormation works out the delta.
Changing `InstanceType` replaces the instance, and `/data` does not follow it
automatically. Snapshot first.

```bash
INSTANCE_TYPE=t4g.large ./deploy.sh monitoring
```

**Update container images:**

```bash
aws ssm start-session --target "$INSTANCE"
cd /opt/monitoring && sudo docker compose --profile full pull
sudo docker compose --profile full up -d
```

Image tags are pinned (`loki:3.1.1`, `grafana-oss:11.2.0`, `ntfy:v2`) deliberately, so
a reboot can't silently move you to a breaking release. Bump them in the template when
you choose to.

**Add a home node:** re-run `install-child.sh` there. Nothing on the parent changes.

**Rotate the Tailscale key:** only used at first boot. Nothing to rotate unless you
rebuild.

**Tear down:**

```bash
./deploy.sh destroy
```

Three things this does **not** clean up, by design:

1. The `/data` EBS volume, if `DataVolumeDeleteOnTermination` was `false` (the
   default). It keeps your history — and keeps billing you ~$8/mo. Delete it by hand.
2. The node entry in your Tailscale admin console.
3. SSM parameters under `/monitoring/`.

---

# Part 10 — Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Stack fails, no instance left to inspect | Rollback deleted it. Re-run with `DISABLE_ROLLBACK=1`. |
| `CREATE_FAILED` on `MonitorInstance` with "signal FAILURE" | Bootstrap hit an error. `aws ssm start-session` and read `/var/log/monitoring-bootstrap.log`. |
| 25-minute timeout, no signal at all | Failure happened *before* AWS CLI v2 installed, so it couldn't signal. Almost always apt or network. Check `/var/log/cloud-init-output.log`. |
| `mon-aws` never appears in `tailscale status` | Bad/expired/already-used auth key, or `tag:monitor` not defined in ACLs. On the box: `tailscale status`, `journalctl -u tailscaled`. |
| `tailscale up` fails with a tag error | The auth key wasn't created *with* `tag:monitor`. Generate a new tagged key, update SSM, rebuild the instance. |
| `aws ssm start-session` fails | Missing plugin (step 1.2), or the instance has no outbound internet to reach SSM endpoints. |
| Home node not in Netdata's node list | Key mismatch. Compare `/etc/netdata/stream.conf` on the child against SSM. Then `journalctl -u netdata -n 100` on both ends. |
| Netdata child connects then drops | Parent's `allow from` doesn't cover the source. Children arrive from `100.64.0.0/10`; confirm the child connects over the tailnet, not a public path. |
| Loki query returns nothing | Alloy. `journalctl -u alloy -n 50` on the child. Usually the `systemd-journal` group membership didn't take — needs a service restart. |
| Grafana won't accept the password | Read it from SSM (Part 8). If it was rotated in SSM after boot, Grafana still has the original in its own DB. |
| `/data` not mounted, containers won't start | Volume detection failed. `lsblk`, then check the device-detection block in the bootstrap log. |
| Everything worked, then died after a reboot | `docker` enabled? `systemctl is-enabled docker`. Containers use `restart: unless-stopped`, so they should return on their own. |

---

# Design notes worth knowing

- **Zero inbound security-group rules.** Not a typo. Tailscale needs outbound only,
  and metrics/logs are pushed to this node.
- **No SSH key pair exists anywhere in the stack.** Tailscale SSH, or SSM Session
  Manager as break-glass.
- **Secrets via SSM SecureString, not CFN parameters** — they stay out of UserData
  and stack history.
- **The data volume is a `BlockDeviceMapping`, not a separate `Volume` +
  `VolumeAttachment`.** That combination deadlocks: an attachment `DependsOn` the
  instance, the instance isn't `CREATE_COMPLETE` until it signals, and it can't
  signal until `/data` is mounted.
- **Netdata's dbengine cache is bind-mounted onto `/data`** rather than configured in
  `netdata.conf`, because the config key for the cache directory has moved between
  releases. The bind mount is version-proof.
- **No NAT gateway.** ~$32/mo and pointless when the security group already blocks
  everything inbound.
- **Netdata backfills on reconnect**, so a home internet blip leaves a gap that
  mostly heals rather than a permanent hole.

## Is AWS the right place for this?

Probably not on cost alone. A Hetzner CAX11 — 2 vCPU ARM, 4 GB, 40 GB, ~€3.79/mo, no
IPv4 surcharge — runs this entire stack for less than the AWS *watchdog* option, with
more RAM than the `t4g.medium`. That's roughly 8x cheaper for identical function.

EC2 earns its place if you also want the Terraform/IAM/CloudFormation reps alongside
your dbdeployer work. That's a legitimate reason; it just isn't a cost one.

Nothing in the bootstrap is deeply AWS-specific — only the SSM secret fetch and the
CloudFormation signal. It ports to any VPS with modest edits.

## Status and known unknowns

Statically verified: `cfn-lint` clean on both templates; the extracted UserData is
`bash -n` clean; every `${...}` in UserData resolves to a real parameter; the embedded
compose, Loki, datasource YAML and `daemon.json` all parse; `deploy.sh` and
`install-child.sh` are syntax-clean.

**Not deployed, so not runtime-tested.** Likely first-boot friction, in order:

1. `SEND_NTFY` support in Netdata's `health_alarm_notify.conf` — probably present in
   current builds, not certain. Part 7.1 verifies it and gives the fallback.
2. Loki 3.1.1 config schema — pinned deliberately, but not run.
3. `PUBLIC_IPV4=false` (the IPv6-only path that saves $3.65/mo) is the least-tested
   option. Leave it `true` for your first deploy.

## Still to do

- Ansible roles for the child side (`netdata_child`, `alloy`) to replace
  `install-child.sh`, in the `ansible/` tree alongside the retargeted `pve` inventory.
- No Prometheus, so no PromQL or dashboards-as-code.
- Grafana has no dashboards provisioned beyond the Loki datasource.

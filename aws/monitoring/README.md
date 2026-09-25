# Tailnet monitoring node — deployment runbook

Builds an always-on **external** monitoring host in AWS, joined to your tailnet, that
watches **tav-serv** — the Dell R610 running Proxmox VE — and its guests.

External on purpose: tav-serv is the only home hypervisor, so anything running *on*
tav-serv cannot tell you when tav-serv has died. That single fact drives the whole
design, and it is the same reason three "HA" Postgres nodes on one box are not
host-level HA.

```
                        tailnet (WireGuard)
  ┌────────────────┐                             ┌───────────────────────────────┐
  │ tav-serv (PVE) │─ netdata child ──── push ──▶│ mon-aws  (EC2 Graviton)        │
  │  ├ TrueNAS VM  │─ alloy (journal) ── push ──▶│   netdata parent      :19999   │
  │  ├ kieran-craft│                             │   uptime-kuma         :3001    │
  │  └ autobase +  │◀──── synthetic probes ──────│   ntfy                :8080    │
  │     pgnode01-3 │                             │   loki                :3100    │
  └────────────────┘                             │   grafana             :3000    │
  ┌────────────────┐                             │                               │
  │ tavares-lab /  │──── browser / app ─────────▶│                               │
  │ phone          │                             └───────────────────────────────┘
  └────────────────┘                              Security group: ZERO inbound rules
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

`tailscale` was not found on PATH or in `C:\Program Files\Tailscale\` on
`tavares-lab`. Reinstall it — the workstation needs to be on the tailnet both to
reach the monitoring UIs and to run the Ansible control node against tav-serv.

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

### The `users` list is what makes SSH work — and it is not obvious

`tailscale up --ssh` means SSH to this node is authenticated by **tailnet identity**:
no key, no password, no `authorized_keys`. The `users` list above is the authorisation
decision — it names which *local* accounts a tailnet member may become.

So `ssh ubuntu@mon-aws` and `ssh root@mon-aws` work today with no credential at all.
If you deploy with `ADMIN_USER=alice`, **you must add `"alice"` to this list too**, or
Tailscale refuses the connection — and the refusal looks like an ordinary login
failure, not a policy error, which sends you looking at the node instead of the ACL.

Consider narrowing rather than widening: dropping `"root"` once a named admin with
`sudo` exists removes direct remote root while costing you nothing, because the named
account has passwordless `sudo`.

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

Without it, a bootstrap failure rolls the stack back and deletes the instance. With
it, the instance survives for inspection and you delete the stack by hand afterwards.

The deploy follows the bootstrap log live while it blocks — the instance flushes to
CloudWatch at every stage boundary, so you see progress as it happens rather than a
silent 10-minute wait. `WATCH=0` disables it.

### If it fails, you get a diagnostic file automatically

On a failed deploy, `deploy.sh` collects everything into a single local
`diag-<timestamp>.txt` and prints the verdict. You can also run it on demand:

```bash
./deploy.sh diag
```

That file has, in order: stack status, the failure events only, the full bootstrap log
from CloudWatch, status-check alarm history (i.e. did auto-recovery fire), CloudTrail
`RecoverInstance` events, detached volumes still billing, and the full event history.
It is one file to read or hand over.

The bootstrap log lives in CloudWatch **on both success and failure**, written before
the instance signals CloudFormation, so it survives the rollback that deletes the
instance. On its own:

```bash
./deploy.sh logs
```

Look for three things in the output:

| Marker | Meaning |
| --- | --- |
| `=== STAGE: <name>` | how far the bootstrap got — the last one printed is where it died |
| `=== result=FAILURE stage=<name>` | the verdict line, written by the exit trap |
| `=== failed near line N running: <cmd>` | the exact command that returned non-zero |

The stages, in order: `apt`, `awscli`, `logsetup`, `ssm`, `volume`, `docker`,
`tailscale_pkg`, `tailscale_up`, `netdata`, `grafana_pw`, `compose`, `compose_up`.

This is why `DISABLE_ROLLBACK=1` is now a convenience rather than a necessity — but
keep using it on a first deploy, because a surviving instance lets you fix things
interactively instead of redeploying to test each guess.

### Also check for an orphaned volume

`DataVolumeDeleteOnTermination` defaults to `false` on purpose — your metrics and logs
should not evaporate because a stack update replaced the instance. The flip side is
that a **failed** deploy leaves the data volume behind, detached and still billing
(~$8/mo for 100GB):

```bash
./deploy.sh orphans
```

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

## 3.5 Getting a shell

Two ways in, and **neither uses an SSH key or a password**. The security group has
zero inbound rules, so there is no port to attack in the first place.

```bash
ssh ubuntu@mon-aws          # works immediately, no setup at all
ssh root@mon-aws            # also works; both are in the ACL users list
```

`ubuntu` ships with the Ubuntu AMI and already has passwordless `sudo` via
`/etc/sudoers.d/90-cloud-init-users`. **For most purposes you need nothing more than
this.** Verify with:

```bash
ssh ubuntu@mon-aws 'whoami; sudo -n true && echo "sudo ok"; groups'
```

### A named admin instead

If you want your own account rather than the generic one, deploy with `ADMIN_USER`:

```bash
ADMIN_USER=mtavares \
ADMIN_SSH_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  MODE=FullStack ALERT_EMAIL=you@example.com ./deploy.sh monitoring
```

`ADMIN_SSH_KEY` is optional; Tailscale SSH needs no key. Both are optional.

The account is created with its **password locked**. That is deliberate:

- Tailscale SSH already authenticates by tailnet identity, so a password would add no
  security. It would *subtract* some — a guessable credential where there was none,
  and the only credential on the box not held in SSM.
- Because the password is locked, `sudo` group membership alone would leave `sudo`
  **unusable** — it would prompt for a password nothing can satisfy. The template
  therefore also writes `/etc/sudoers.d/90-<user>` with `NOPASSWD:ALL`, mirroring
  what the AMI already does for `ubuntu`.

**Two things that bite:**

1. **Add the username to the Tailscale ACL `users` list** (§2.1) or the SSH is
   refused, and the error looks like a normal login failure rather than policy.
   `./deploy.sh preflight` reminds you when `ADMIN_USER` is set.
2. **`UserData` changes force instance replacement.** Adding `ADMIN_USER` to an
   *existing* stack will **destroy and rebuild the node** — which means a fresh
   Tailscale auth key, and a bad key is what killed the first two deploys. To get the
   account onto the running node without a rebuild, do it by hand (below) and keep the
   template change purely for the next rebuild. Run `./deploy.sh monitoring` with the
   new variables only when you actually intend to replace the instance.

To add it to the **live** node with no rebuild — same result as the template produces:

```bash
U=mtavares
ssh root@mon-aws "
  id -u $U >/dev/null 2>&1 || useradd -m -s /bin/bash $U
  usermod -aG sudo,docker,adm,systemd-journal $U
  passwd -l $U
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' $U > /tmp/s.new
  visudo -cf /tmp/s.new && install -m 0440 -o root -g root /tmp/s.new /etc/sudoers.d/90-$U
  rm -f /tmp/s.new
  id $U"
```

Then add `"mtavares"` to the ACL `users` list and `ssh mtavares@mon-aws`.

### If Tailscale itself is down

Neither path above works — the node has no open ports. SSM Session Manager is the
only way in, and it goes through the AWS API rather than the network:

```bash
aws ssm start-session --target "$(aws cloudformation describe-stack-resources \
  --stack-name mon-node --logical-resource-id MonitorInstance \
  --query 'StackResources[0].PhysicalResourceId' --output text)"
```

Needs `session-manager-plugin` locally; `./deploy.sh preflight` warns if it is absent.

---

# Part 4 — Verify the node

## 4.0 The one command that checks everything

```bash
CHILDREN="pve" ./healthcheck.sh
```

Read-only, safe to run any time. It walks four layers and prints PASS/WARN/FAIL with
a non-zero exit if anything failed:

1. **This workstation** — is Tailscale up, does `mon-aws` resolve.
2. **AWS control plane** — stack status, instance running, both status-check alarms
   present *and* `TreatMissingData=missing` (guards against the recovery-loop
   regression), **SNS subscription confirmed**, SSM parameters present, no orphaned
   volumes, bootstrap log shows `result=SUCCESS`.
3. **Services** — Netdata :19999, Uptime Kuma :3001, ntfy :8080, Grafana :3000,
   Loki :3100.
4. **Telemetry actually flowing** — which children the parent is mirroring, whether
   Loki has ever received a log line, and whether Netdata's health engine is on
   (a parent with zero alarms defined will never notify anyone).

`--no-aws` skips layer 2. `MON_HOST=localhost` to run it on the node itself.

**Run it from somewhere on the tailnet.** The Linux Mint workstation is a tailnet
member, so just run it there directly. The MathWorks-managed Windows laptop is **not**
one — every layer-3 check fails there regardless of how healthy the node is. To run it
on another host without cloning the repo:

```bash
ssh root@192.168.1.226 'MON_HOST=mon-aws CHILDREN=pve bash -s' < healthcheck.sh
```

Use `bash healthcheck.sh` rather than `./healthcheck.sh` if the exec bit is missing —
it doesn't survive a clone made on Windows. Don't use `sudo`: the script is read-only
and needs *your* AWS credentials and *your* tailscale session, both of which root lacks.

It forces `curl --noproxy '*'`, which matters on a corporate-managed machine: with
`http_proxy` set, curl sends tailnet requests to the company proxy, which has no route
to `100.64.0.0/10` and returns **502** — indistinguishable from a broken service.

A fully healthy `FullStack` deployment with the hypervisor onboarded reads
**24 PASS / 0 WARN / 0 FAIL** (first achieved 2026-09-25).

## 4.1 Manual checks

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

# one command, so it cannot half-run: ships both files and executes them.
# Doing it as separate scp + ssh steps repeatedly failed with
# "bash: install-child.sh: No such file or directory" because the scp got skipped.
# config.alloy must travel too -- the script reads it from its own directory.
tar cz -C home-node install-child.sh config.alloy \
  | ssh root@192.168.1.226 'mkdir -p /tmp/mon && tar xz -C /tmp/mon && cd /tmp/mon &&
      MON_HOST=mon-aws ND_KEY='"$ND_KEY"' SEND_LOGS=yes bash install-child.sh'
```

The script installs Netdata as a child (`memory mode = ram`, local health disabled so
alarms only fire once, from the parent) and Grafana Alloy to ship the journal to Loki.
It adds the `alloy` user to `systemd-journal`, without which Alloy silently reads
nothing.

Verify within about a minute:

```bash
ssh root@192.168.1.226 "systemctl status netdata alloy --no-pager | grep -E 'Active|●'"
```

Then check <http://mon-aws:19999>. The hypervisor appears under its **own hostname**,
which is `pve` — not `tav-serv`. A Netdata child registers whatever `hostname` returns,
so that is also the value to pass to `healthcheck.sh`:

```bash
CHILDREN="pve" ./healthcheck.sh
```

If it does *not* appear, read the `allow from` note in [Part 10](#part-10--troubleshooting)
**before** suspecting the api key. That mistake cost a day on 2026-09-25.

## 5.2 Guest VMs and containers

Same command, per guest. Run it only where it earns its keep:

| Guest | Do this |
|---|---|
| `kieran-craft` (Minecraft) | Run the script. Debian/Ubuntu based, works as-is. |
| `pgnode01-03` | Run the script — these are the ones where per-process and disk-latency metrics earn their keep. Ubuntu 24.04, works as-is. Netdata also auto-detects the local PostgreSQL and PgBouncer once Autobase has deployed them. |
| `autobase-console` | Optional. It's a Docker host, so the cgroup collector gives you per-container CPU/RAM for the four Console services. |
| **TrueNAS SCALE (VM 100)** | **Do not run the script.** SCALE is an appliance — packages installed by hand don't survive upgrades. Monitor it with Uptime Kuma probes plus its own built-in reporting. Hypervisor-level CPU/RAM/disk still comes from tav-serv. |
| LXC containers | The script works, but many collectors are limited inside a container. Often not worth it — the host's cgroup metrics already cover resource use. |

The guests are not on the tailnet themselves; they reach `mon-aws` outbound through
tav-serv's subnet route, which is all a push-based child needs.

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
| PVE web UI | HTTP(s) | `https://tav-serv:8006` | Turn **off** certificate validation (self-signed). |
| TrueNAS UI | HTTP(s) | `https://<truenas>` | Certificate validation off. |
| Minecraft | TCP Port | `tav-serv` : `25565` | Port check, not HTTP. |
| BlueMap | HTTP(s) | `http://tav-serv:8100` | |
| Autobase Console | HTTP(s) | `https://autobase` | Via `tailscale serve` on the console VM. |
| Postgres VIP | TCP Port | `<autobase_cluster_vip>` : `5432` | The write endpoint. Down = no primary, which is the alarm you actually want. |
| PgBouncer VIP | TCP Port | `<autobase_cluster_vip>` : `6432` | |
| **Home heartbeat** | **Push** | — | **The important one. See below.** |

## 6.1 The heartbeat monitor — the alarm that matters most

Every monitor above tells you a *service* is down. The push monitor tells you the
*house* is down, which is the reason this node is in AWS at all.

Create a **Push** monitor, set the heartbeat interval to 120 seconds, and copy its
push URL. Then on tav-serv:

```bash
ssh root@tav-serv
cat >/etc/cron.d/uptime-heartbeat <<'EOF'
* * * * * root curl -fsS --max-time 20 "http://mon-aws:3001/api/push/<TOKEN>" >/dev/null 2>&1
EOF
systemctl restart cron
```

Substitute the real token. If tav-serv dies, loses power, or your internet drops, the
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

## 8.1 The log dashboard

`dashboards/journal-logs.json` — import via **Dashboards → New → Import → Upload JSON**.
It is a **logs** dashboard, because Loki is the only datasource; see the caveat above
for why there is nothing metric-shaped to plot.

It has no hardcoded datasource UID. The datasource is a dashboard variable, so import
prompts you to pick Loki rather than silently binding to a UID that differs between
rebuilds — the provisioned one is currently `P8E80F9AEF21F6940`, which is derived, not
stable, and hardcoding it is the single most common reason an imported dashboard shows
"datasource not found" after a redeploy.

Variables: **Datasource**, **Host** (multi), **Unit** (multi), **Search** (free text,
substituted into a LogQL line filter). Panels: line/error/warning counts, hosts
shipping, lines/sec by host and by priority, top 15 noisiest units, errors/sec by unit,
then the two log streams.

**Verify the labels exist before trusting the numbers.** Every panel depends on the
four labels that `home-node/config.alloy` promotes, and a stat panel reading `0`
because a label is *absent* looks identical to one reading `0` because all is well:

```bash
for l in job host unit level; do
  printf '%-6s ' "$l"
  curl -s --noproxy '*' "http://mon-aws:3100/loki/api/v1/label/$l/values" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data") or "NO VALUES")'
done
```

**What that actually returned on 2026-09-25, versus what `config.alloy` says:**

| Label | Configured | Live | Note |
|---|---|---|---|
| `job` | `systemd-journal` | **`loki.source.journal.journal`** | The `labels` argument loses to Alloy's component id. Now forced by a relabel rule instead — relabel runs last. |
| `host` | — | `Tavares-lab`, `hermes`, `kieran-craft`, `pve` | **Four** shippers, not two. |
| `unit` | — | ~80 values, **~60 of them `session-NN.scope`** | Cardinality. Now collapsed to `user-session`. |
| `level` | — | `alert`, `crit`, **`error`**, `info`, `notice`, `warning`, `debug` | **`error`, not the journal's `err`.** |

Those last two rows are the ones that silently break things, and both did:

- **`job` was wrong, so every query matched nothing.** A dashboard written against the
  value you configured returns zero rows while Loki is healthy and full of data — there
  is no error, just empty panels. **Always read the label back from the API, never from
  `config.alloy`.**
- **Loki regex matchers are fully anchored**, so `level=~"err|..."` does *not* match
  `error`. An error panel reads `0` while errors are arriving. The dashboard now matches
  `err|error|crit|alert|emerg` to cover both spellings.

`level` remains the fragile one: it comes from `__journal_priority_keyword`, which Alloy
*derives* from the numeric `PRIORITY` rather than a field the journal ships, so it is the
likeliest to change or vanish across Alloy versions.

**The log and metric paths do not cover the same hosts.** `hermes` and `kieran-craft`
ship logs but are not Netdata children, `mon-aws` ships neither, and only `pve` and
`Tavares-lab` do both. So neither system alone tells you a host is healthy.

To pick up the `config.alloy` fixes, re-run `install-child.sh` on each shipper. Not
urgent — the dashboard works against either label set — but until you do, `job` stays
`loki.source.journal.journal` and the session-scope streams keep accumulating. Existing
streams also keep their old `job` value until they age out of the 720h window, so query
with `job=~".+"` across the transition.

Two panels are worth understanding rather than just reading:

- **Hosts shipping logs** goes red below 2. Netdata streaming and Alloy log shipping are
  **independent paths over the same tailnet** — a child can be perfectly healthy in
  `mirrored_hosts` while its Alloy has been dead for a week. `healthcheck.sh` only
  asserts that Loki has *a* `job` label, which one working shipper satisfies. This panel
  is the thing that notices the second one stopping.
- **Top 15 noisiest units** is a capacity panel, not a curiosity. Each distinct
  `{host, unit, level}` combination is its own Loki stream, and stream count is what
  Loki's cost and memory scale with — not bytes. `config.alloy` deliberately promotes
  only three fields for this reason.

Not provisioned into Grafana on purpose: adding it to the template's provisioning
directory would mean a `UserData` change, which replaces the instance. Import it by
hand, or copy it to `/opt/monitoring/provisioning/dashboards/` on the running node and
restart the Grafana container.

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

**Start here for any deploy failure:** `./deploy.sh diag`. One file, verdict at the top.
See [3.3](#33-deploy-the-monitoring-node) for how to read the stage markers.

| Symptom | Cause and fix |
|---|---|
| Stack fails, no instance left to inspect | Rollback deleted it, but not the log. `./deploy.sh logs`. Then `./deploy.sh orphans` — the data volume outlives the instance and keeps billing. |
| `CREATE_FAILED` on `MonitorInstance` with "signal FAILURE" | Bootstrap hit an error and the exit trap reported it honestly. `./deploy.sh logs` and read the `=== failed near line` line. If the instance is still up (`DISABLE_ROLLBACK=1`), `aws ssm start-session` and read `/var/log/monitoring-bootstrap.log` directly. |
| 25-minute timeout, no signal at all | Failure happened *before* AWS CLI v2 installed, so it could neither ship the log nor signal. Almost always apt or network. Check `/var/log/cloud-init-output.log` on the box. |
| Failed at `stage ssm` | The instance role couldn't read the SecureString, or KMS denied the decrypt. The log echoes the real API error per retry attempt (5 tries, 5s apart). Confirm the parameter names match what you passed and that they are the same region as the stack. |
| Got an EC2 "instance recovered" email, node went unresponsive, stack rolled back | The `StatusCheckFailed_System` alarm fired `ec2:recover` when it shouldn't have. Fixed 2026-09-17: `TreatMissingData` was `breaching`, which counts the absence of status-check data as a failure — and that data is legitimately absent on a launching instance and during recovery itself, making it self-reinforcing. Now `missing`, with 2-of-3 datapoints. Note that recovery preserves the instance id, so cloud-init will **not** re-run UserData afterwards: if recovery fires mid-bootstrap the stack can never be signalled and must be redeployed, not waited on. |
| Failed at `stage volume` | Device never appeared, or `blkid` returned no UUID for a filesystem that was just created. The log dumps `lsblk` and `findmnt` output before the wait loop — compare the disk list against what you expected. |
| `mon-aws` never appears in `tailscale status` | Bad/expired/already-used auth key, or `tag:monitor` not defined in ACLs. On the box: `tailscale status`, `journalctl -u tailscaled`. |
| `tailscale up` fails with a tag error | The auth key wasn't created *with* `tag:monitor`. Generate a new tagged key, update SSM, rebuild the instance. |
| `aws ssm start-session` fails | Missing plugin (step 1.2), or the instance has no outbound internet to reach SSM endpoints. |
| "Netdata on pve only listens on 127.0.0.1, it's unreachable from outside" | **Not a fault — that is the design.** `install-child.sh` sets `bind to = 127.0.0.1` deliberately. A child never accepts connections; it opens an *outbound* stream to the parent and pushes metrics up it. Do not open 19999 on `pve` or poke a hole in the Proxmox firewall: it buys nothing and costs you a listening service. The correct test of a child is whether it appears in the **parent's** node list — `./healthcheck.sh` does exactly that. |
| Every service check fails with HTTP 502 | Your shell has `http_proxy`/`HTTPS_PROXY` set and curl is routing tailnet requests through the corporate proxy, which can't reach `100.64.0.0/10`. `healthcheck.sh` already passes `--noproxy '*'`; if testing by hand, do the same. |
| **Parent is healthy but mirrors only itself — no child ever appears** | **Check `allow from` in the parent's `/etc/netdata/stream.conf` first, before the api key.** It takes netdata **simple patterns (globs), not CIDR**. The bootstrap originally wrote `allow from = 100.64.0.0/10 127.0.0.1`; netdata compares that as a literal string, so it matched no child and silently refused every one — while the parent kept mirroring *itself* (via the literal `127.0.0.1`) and so looked perfectly alive. Correct value is `allow from = 100.* 127.0.0.1`. Diagnose decisively by widening to `allow from = *` and restarting netdata: children appear within ~20s if this was it. Safe to test because the security group has zero inbound rules. Fixed in the template 2026-09-25; cost a day, and three separate agents all misdiagnosed it as a key mismatch. |
| Child configured correctly but rejected | The parent's `stream.conf` is written **once at bootstrap** and does **not** follow later SSM changes, so **SSM is not authoritative — the parent's `[section]` header is.** Rotating the SSM key alone breaks streaming. Compare them: `ssh root@mon-aws 'grep "^\[" /etc/netdata/stream.conf'` against `aws ssm get-parameter --name /monitoring/netdata-stream-key --with-decryption --query Parameter.Value --output text`. Multiple `[key]` sections are allowed, which is what makes a zero-downtime rotation possible: add the new section, move the children, then remove the old one. |
| `ip-10-30-1-101` in the node list looks like stray config | It isn't. That's the parent's own hostname (EC2 derives it from the private IP) and a parent always mirrors itself. Cosmetic fix: set `hostname = mon-aws` in `/etc/netdata/netdata.conf`. |
| Alarms are `OK`, stack is `CREATE_COMPLETE`, but no email ever arrives | The SNS topic has **zero subscriptions**. An inline `Subscription:` property on `AWS::SNS::Topic` is write-once — CFN creates it and never reconciles it, so one click on the unsubscribe link in any SNS email kills delivery permanently and silently. Fixed 2026-09-25: it's now a standalone `AWS::SNS::Subscription` resource. To restore delivery on a *running* stack, subscribe by hand and click the confirmation — **do not** run a stack update for this, because a `UserData` diff replaces the instance. `healthcheck.sh` treats both zero and `PendingConfirmation` as FAIL. |
| `install-child.sh` → `No such file or directory` | The script was never copied to the target. Use the single `tar cz \| ssh` form in [5.1](#51-the-proxmox-host--do-this-one-first) so the copy can't be skipped, and remember `config.alloy` must travel with it. |
| Child's config isn't where you expect | Netdata's kickstart falls back to a **static** install under `/opt/netdata` on any distro it can't identify (e.g. Linux Mint), so the config is `/opt/netdata/etc/netdata/`, not `/etc/netdata/`, and it logs to the journal rather than `error.log`. Debian/Proxmox gets native packages and `/etc/netdata/`. `install-child.sh` detects this; commands you type by hand do not. |
| Home node not in Netdata's node list | Key mismatch. Compare `/etc/netdata/stream.conf` on the child against SSM. Then `journalctl -u netdata -n 100` on both ends. |
| Netdata child connects then drops | Parent's `allow from` doesn't cover the source. Children arrive from `100.64.0.0/10`; confirm the child connects over the tailnet, not a public path. |
| Loki query returns nothing | Alloy. `journalctl -u alloy -n 50` on the child. Usually the `systemd-journal` group membership didn't take — needs a service restart. |
| Grafana won't accept the password | Read it from SSM (Part 8). If it was rotated in SSM after boot, Grafana still has the original in its own DB. |
| Grafana: "Unable to retrieve metric names" / "unable to connect to your data source (Internal Server Error)" | **Not a fault.** You are in **Explore → Metrics**, which needs a **Prometheus** datasource, and there isn't one — only Loki is provisioned. Grafana falls back to the built-in `-- Grafana --` pseudo-datasource (`var-ds=grafana` in the URL), which has no metrics API, so it 500s with `data source not found`. Metrics live in **Netdata's own UI on :19999**, which is the metrics front end for all hosts; use Grafana for **Explore → Logs → Loki**. Confirm Loki itself is fine with `curl -s -u admin:$GFPASS http://mon-aws:3000/api/datasources/1/health` → `"status":"OK"`. Datasource ids other than `1` do not exist, so probing `/api/datasources/2/health` returns this same misleading error. Wanting metrics *in* Grafana means adding a real Prometheus that scrapes `mon-aws:19999/api/v1/allmetrics?format=prometheus` — Netdata's endpoint is a scrape target, not a query API, so it cannot back a Prometheus datasource directly. |
| `ssh <user>@mon-aws` refused, but `ssh ubuntu@mon-aws` works | The username isn't in the Tailscale ACL `ssh` block's `users` list (§2.1). Tailscale SSH authorises per *local account*, and the refusal is indistinguishable from an ordinary login failure, so this sends you to the node when the problem is in the policy. Creating the account on the box is only half the job. |
| Named admin exists, `sudo` asks for a password you never set | Expected if the account was created without the sudoers drop-in: the password is deliberately locked, so `%sudo` group membership alone leaves `sudo` unusable. Needs `/etc/sudoers.d/90-<user>` with `NOPASSWD:ALL` — see [3.5](#35-getting-a-shell). Always `visudo -cf` before installing it; a malformed sudoers file breaks `sudo` for everyone including root recovery. |
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
- **The bootstrap log is shipped to CloudWatch by the instance, not by a
  CloudFormation-managed log group.** A group declared in the template would either be
  deleted by the same rollback whose evidence you need, or collide on the next attempt.
  The instance creates it with a 14-day retention and it is deliberately left behind by
  `destroy` (~pennies, and post-mortems shouldn't self-destruct).

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

**Deploy attempt 2026-09-15 failed** at `MonitorInstance` — "Received FAILURE signal",
94 seconds after launch. Everything up to the instance created cleanly. Because the
signal *arrived*, the AWS CLI was installed and had working credentials, which puts the
failure at the SSM secret fetch or the volume detect/format step. The rollback deleted
the instance and its log, so the exact cause is not recoverable from that run. The
CloudWatch shipping, ERR trap, stage markers, retrying SSM fetch and `udevadm settle`
retry described above were all added in response; a repeat failure will name its own
cause. **No cause has been confirmed — do not treat any of those fixes as "the fix".**

Other likely first-boot friction, in order:

1. `SEND_NTFY` support in Netdata's `health_alarm_notify.conf` — probably present in
   current builds, not certain. Part 7.1 verifies it and gives the fallback.
2. Loki 3.1.1 config schema — pinned deliberately, but not run.
3. `PUBLIC_IPV4=false` (the IPv6-only path that saves $3.65/mo) is the least-tested
   option. Leave it `true` for your first deploy.

## Still to do

- Ansible roles for the child side (`netdata_child`, `alloy`) to replace
  `install-child.sh`. They belong in the `ansible/` tree, where `inventory/hosts.ini`
  already has tav-serv and the platform guests as targets.
- No Prometheus, so no PromQL or dashboards-as-code.
- Grafana has no dashboards provisioned beyond the Loki datasource.

#!/usr/bin/env bash
# Verify every layer of the tailnet monitoring deployment. Read-only: this script
# changes nothing, so it is safe to run any time.
#
#   ./healthcheck.sh                     full check (AWS control plane + services)
#   ./healthcheck.sh --no-aws            skip AWS API checks (no creds needed)
#   CHILDREN="pve truenas" ./healthcheck.sh
#
# Env:
#   MON_HOST    default mon-aws     MagicDNS name or tailnet IP of the node
#   CHILDREN    space-separated list of hostnames you EXPECT to be streaming
#   MODE        FullStack | WatchdogOnly   default FullStack
#   AWS_REGION  default us-east-1
#   STACK       default mon-node
#   TIMEOUT     default 8           per-request curl timeout in seconds
#
# IMPORTANT, because it is counter-intuitive and people "fix" it by mistake:
# Netdata on a CHILD is deliberately bound to 127.0.0.1 only. Children are not
# meant to be reachable from anywhere -- they open an OUTBOUND stream to the
# parent and push metrics up it. So "pve:19999 refused from my laptop" is the
# design working, not a fault. The only correct test of a child is whether it
# shows up in the PARENT's node list, which is what this script checks.

set -uo pipefail

MON_HOST="${MON_HOST:-mon-aws}"
CHILDREN="${CHILDREN:-}"
MODE="${MODE:-FullStack}"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK:-mon-node}"
TIMEOUT="${TIMEOUT:-8}"
LOG_GROUP="${LOG_GROUP:-/tavlab/monitoring-bootstrap}"
TS_KEY_PARAM=/monitoring/tailscale-authkey
ND_KEY_PARAM=/monitoring/netdata-stream-key
GF_PW_PARAM=/monitoring/grafana-admin-password

DO_AWS=1
[ "${1:-}" = "--no-aws" ] && DO_AWS=0

export AWS_PAGER=""
AWS="aws --region $AWS_REGION"

PASS=0; WARN=0; FAIL=0
if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'
else
  G=""; Y=""; R=""; B=""; Z=""
fi

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s  %s\n' "$Y" "$Z" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"; }
note() { printf '        %s\n' "$1"; }
head_() { printf '\n%s== %s%s\n' "$B" "$1" "$Z"; }

# --noproxy '*' costs nothing on the Linux Mint box (no proxy set) but is not
# optional if this is ever run from the MathWorks-managed laptop: with http_proxy
# in the environment, curl sends tailnet requests to the company proxy, which has
# no route to 100.64/10 and answers 502 -- indistinguishable from a dead service.
# Tailnet traffic must never traverse a proxy. Keep this even if it looks inert.
CURL=(curl --noproxy '*' --max-time "$TIMEOUT")

# http() is almost always called as $(http ...), i.e. in a subshell, so it cannot
# hand the status code back in a variable -- the assignment would be lost with the
# subshell. It goes via a temp file instead; hcode() reads it in the caller.
CODEFILE=$(mktemp 2>/dev/null || echo "/tmp/hc.$$.code")
trap 'rm -f "$CODEFILE"' EXIT

# HTTP GET -> body on stdout, returns 0 only on a 2xx. Never aborts the script.
http() {
  local out code
  out=$("${CURL[@]}" -s -w '\n%{http_code}' "$1" 2>/dev/null)
  code="${out##*$'\n'}"
  case "$code" in ''|*[!0-9]*) code=000 ;; esac
  printf '%s' "$code" > "$CODEFILE"
  printf '%s' "${out%$'\n'*}"
  case "$code" in 2*) return 0 ;; *) return 1 ;; esac
}

hcode() { cat "$CODEFILE" 2>/dev/null || echo 000; }

# Prefer python for JSON; it is the one interpreter we know is on this box.
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

json_get() {  # json_get <json> <python expression over 'd'>
  [ -n "$PY" ] || return 1
  printf '%s' "$1" | "$PY" -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
try:
    v=($2)
except Exception:
    sys.exit(1)
print(v if v is not None else '')
" 2>/dev/null
}

# ----------------------------------------------------------------- 1. local side
head_ "1. This workstation"

if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    ok "tailscale is running locally"
  else
    bad "tailscale is installed but not connected -- run 'tailscale up'"
    note "every service below is tailnet-only, so nothing else can pass"
  fi
else
  warn "tailscale not on PATH here"
  note "this machine is not on the tailnet, so every service check below will fail"
  note "regardless of the node's actual health. Run it from a tailnet member --"
  note "the Linux Mint workstation, or tav-serv -- or pipe it to one:"
  note "  ssh root@tav-serv 'MON_HOST=mon-aws CHILDREN=tav-serv bash -s' < healthcheck.sh"
  note "or on the node itself: ssh root@mon-aws 'MON_HOST=localhost bash -s' < healthcheck.sh"
fi

if [ -n "${http_proxy:-}${HTTP_PROXY:-}${all_proxy:-}" ]; then
  note "an HTTP proxy is set in this environment; bypassing it for tailnet hosts"
fi

if [ "$MON_HOST" != "localhost" ] && [ "$MON_HOST" != "127.0.0.1" ]; then
  # Linux flags first (this runs on Linux Mint / Debian in practice); the
  # Windows form is the fallback for a Git-Bash run on the work laptop, where
  # -c/-W are unrecognised and -n/-w mean count/timeout instead.
  if ping -c 1 -W 3 "$MON_HOST" >/dev/null 2>&1 \
     || ping -n 1 -w 3000 "$MON_HOST" >/dev/null 2>&1; then
    ok "$MON_HOST resolves and answers ping"
  else
    warn "$MON_HOST did not answer ping"
    note "MagicDNS may not be resolving, or ICMP is filtered. If the HTTP checks"
    note "below pass, ignore this. If they all fail, try the tailnet IP:"
    note "  tailscale status | grep $MON_HOST"
  fi
fi

# ------------------------------------------------------- 2. AWS control plane
if [ "$DO_AWS" = "1" ]; then
  head_ "2. AWS control plane"

  if ! $AWS sts get-caller-identity >/dev/null 2>&1; then
    warn "no AWS credentials in this shell -- skipping control-plane checks"
    note "re-run with --no-aws to silence this, or authenticate first"
    DO_AWS=0
  fi
fi

if [ "$DO_AWS" = "1" ]; then
  st=$($AWS cloudformation describe-stacks --stack-name "$STACK" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING)
  case "$st" in
    CREATE_COMPLETE|UPDATE_COMPLETE) ok "stack $STACK is $st" ;;
    MISSING) bad "stack $STACK not found in $AWS_REGION" ;;
    *ROLLBACK*|*FAILED*) bad "stack $STACK is $st -- run './deploy.sh diag'" ;;
    *) warn "stack $STACK is $st" ;;
  esac

  iid=$($AWS cloudformation describe-stack-resources --stack-name "$STACK" \
         --logical-resource-id MonitorInstance \
         --query 'StackResources[0].PhysicalResourceId' --output text 2>/dev/null || echo "")
  if [ -n "$iid" ] && [ "$iid" != "None" ]; then
    read -r state itype <<<"$($AWS ec2 describe-instances --instance-ids "$iid" \
      --query 'Reservations[0].Instances[0].[State.Name,InstanceType]' \
      --output text 2>/dev/null || echo "unknown unknown")"
    if [ "$state" = "running" ]; then ok "instance $iid is running ($itype)"
    else bad "instance $iid is '$state'"; fi
  else
    bad "could not resolve the MonitorInstance physical id"
  fi

  # The alarm that caused the recovery loop. Verify the fix is actually deployed,
  # not just present in the template on disk.
  for a in "$STACK-system-status-failed" "$STACK-instance-status-failed"; do
    read -r astate amissing <<<"$($AWS cloudwatch describe-alarms --alarm-names "$a" \
      --query 'MetricAlarms[0].[StateValue,TreatMissingData]' --output text 2>/dev/null \
      || echo "MISSING MISSING")"
    case "$astate" in
      OK) ok "alarm $a is OK" ;;
      ALARM) bad "alarm $a is in ALARM" ;;
      INSUFFICIENT_DATA) warn "alarm $a has INSUFFICIENT_DATA (normal for ~5m after a launch)" ;;
      *) bad "alarm $a not found" ;;
    esac
    if [ "$amissing" = "breaching" ]; then
      bad "alarm $a has TreatMissingData=breaching -- REGRESSION"
      note "status-check metrics are absent while the instance is not running, so"
      note "'breaching' makes the ec2:recover action self-reinforcing. Must be 'missing'."
    elif [ "$amissing" = "missing" ]; then
      ok "alarm $a treats missing data correctly"
    fi
  done

  # An unconfirmed SNS subscription silently delivers nothing -- easy to miss.
  topic=$($AWS cloudformation describe-stack-resources --stack-name "$STACK" \
    --query 'StackResources[?ResourceType==`AWS::SNS::Topic`].PhysicalResourceId' \
    --output text 2>/dev/null || echo "")
  if [ -n "$topic" ] && [ "$topic" != "None" ]; then
    pending=$($AWS sns list-subscriptions-by-topic --topic-arn "$topic" \
      --query 'length(Subscriptions[?SubscriptionArn==`PendingConfirmation`])' \
      --output text 2>/dev/null || echo 0)
    total=$($AWS sns list-subscriptions-by-topic --topic-arn "$topic" \
      --query 'length(Subscriptions)' --output text 2>/dev/null || echo 0)
    if [ "$total" = "0" ]; then
      bad "SNS topic has no subscriptions -- node-down email will go nowhere"
    elif [ "$pending" != "0" ]; then
      bad "$pending SNS subscription(s) still PendingConfirmation"
      note "unconfirmed subscriptions deliver NOTHING. Check your inbox for the"
      note "AWS confirmation email and click the link."
    else
      ok "SNS subscription(s) confirmed ($total)"
    fi
  else
    warn "no SNS topic in the stack (deployed without ALERT_EMAIL?)"
  fi

  for p in "$TS_KEY_PARAM" "$ND_KEY_PARAM" "$GF_PW_PARAM"; do
    if $AWS ssm get-parameter --name "$p" >/dev/null 2>&1; then ok "SSM $p exists"
    else
      if [ "$p" = "$GF_PW_PARAM" ] && [ "$MODE" = "WatchdogOnly" ]; then
        ok "SSM $p absent (expected in WatchdogOnly)"
      else bad "SSM $p missing"; fi
    fi
  done

  orph=$($AWS ec2 describe-volumes --filters Name=status,Values=available \
    --query 'length(Volumes)' --output text 2>/dev/null || echo 0)
  if [ "$orph" = "0" ]; then ok "no detached EBS volumes billing"
  else
    warn "$orph detached EBS volume(s) in $AWS_REGION still billing (~\$0.08/GB-mo)"
    note "run './deploy.sh orphans' to list and delete them"
  fi

  if $AWS logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
       --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q .; then
    if $AWS logs tail "$LOG_GROUP" --since 30d 2>/dev/null | grep -q "result=SUCCESS"; then
      ok "bootstrap log records a SUCCESS result"
    else
      warn "no 'result=SUCCESS' in the last 30d of $LOG_GROUP"
      note "the running node may predate the CloudWatch shipping change"
    fi
  else
    warn "bootstrap log group $LOG_GROUP does not exist"
  fi
fi

# ------------------------------------------------------------- 3. the services
head_ "3. Services on $MON_HOST"

# Netdata parent -- the one that matters most, and the source of child status.
ND_INFO=""
if ND_INFO=$(http "http://$MON_HOST:19999/api/v1/info"); then
  ver=$(json_get "$ND_INFO" "d.get('version','?')" || echo "?")
  ok "netdata parent responding on :19999 (version ${ver})"
else
  bad "netdata parent NOT responding on http://$MON_HOST:19999 (code $(hcode))"
  note "this is the core of the stack; check 'systemctl status netdata' on the node"
fi

# Kuma redirects / -> /dashboard, so a 3xx is a healthy answer here.
http "http://$MON_HOST:3001" >/dev/null 2>&1 || true
case "$(hcode)" in
  2*|3*) ok "uptime kuma responding on :3001 (code $(hcode))" ;;
  *)     bad "uptime kuma NOT responding on :3001 (code $(hcode))" ;;
esac

if NT=$(http "http://$MON_HOST:8080/v1/health"); then
  if printf '%s' "$NT" | grep -q '"healthy":[[:space:]]*true'; then
    ok "ntfy healthy on :8080"
  else
    bad "ntfy answered on :8080 but is not healthy: $NT"
  fi
else
  bad "ntfy NOT responding on :8080 (code $(hcode))"
  note "netdata alarms are delivered through ntfy, so alerting is down"
fi

if [ "$MODE" = "FullStack" ]; then
  if GH=$(http "http://$MON_HOST:3000/api/health"); then
    dbok=$(json_get "$GH" "d.get('database','?')" || echo "?")
    if [ "$dbok" = "ok" ]; then ok "grafana healthy on :3000 (database ok)"
    else warn "grafana answered on :3000 but database='$dbok'"; fi
  else
    bad "grafana NOT responding on :3000 (code $(hcode))"
  fi

  if LR=$(http "http://$MON_HOST:3100/ready"); then
    if printf '%s' "$LR" | grep -qi ready; then ok "loki ready on :3100"
    else warn "loki on :3100 answered but not ready: $LR"; fi
  else
    bad "loki NOT ready on :3100 (code $(hcode))"
  fi
else
  note "MODE=WatchdogOnly -- skipping grafana and loki"
fi

# ------------------------------------------------- 4. is data actually arriving
head_ "4. Telemetry actually flowing"

# A parent that is up but has no children is the silent failure this whole
# deployment exists to avoid. Children are checked HERE, via the parent, because
# a child binds to 127.0.0.1 and cannot be probed directly by design.
if [ -n "$ND_INFO" ]; then
  hosts=$(json_get "$ND_INFO" "' '.join(d.get('mirrored_hosts',[]))" || echo "")
  if [ -z "$hosts" ]; then
    warn "parent reports no mirrored hosts at all"
    note "no child is streaming. On each child: systemctl status netdata, then"
    note "journalctl -u netdata | grep -i stream"
  else
    n=0; for h in $hosts; do n=$((n+1)); done
    ok "parent is mirroring $n host(s): $hosts"
    if [ -n "$CHILDREN" ]; then
      for want in $CHILDREN; do
        if printf '%s' "$hosts" | tr ' ' '\n' | grep -qix "$want"; then
          ok "expected child '$want' is streaming"
        else
          bad "expected child '$want' is NOT in the parent's node list"
          note "FIRST suspect -- this cost a day on 2026-09-25: 'allow from' in the"
          note "parent's stream.conf takes netdata SIMPLE PATTERNS (globs), NOT CIDR."
          note "A value like '100.64.0.0/10' is compared as a literal string, matches"
          note "no child, and produces exactly this symptom with no visible rejection."
          note "It must read '100.* 127.0.0.1'. Prove it by widening to '*' briefly:"
          note "  ssh root@$MON_HOST 'grep \"allow from\" /etc/netdata/stream.conf'"
          note ""
          note "Second suspect is an api key the PARENT does not accept. The child's"
          note "key must match a [section] header in the parent's stream.conf -- the"
          note "value in SSM is NOT authoritative, because the parent's config was"
          note "written once at bootstrap and does not follow later SSM changes:"
          note "  ssh root@$MON_HOST 'grep \"^\\[\" /etc/netdata/stream.conf'"
          note "  aws ssm get-parameter --name $ND_KEY_PARAM \\"
          note "    --with-decryption --query Parameter.Value --output text"
          note "Then on $want -- note the config dir differs for a STATIC netdata"
          note "install (any distro the kickstart cannot identify, e.g. Linux Mint):"
          note "  CONF=/etc/netdata; [ -d /opt/netdata/etc/netdata ] && CONF=/opt/netdata/etc/netdata"
          note "  grep -E 'destination|api key' \$CONF/stream.conf"
          note "  journalctl -u netdata | grep -i stream | tail"
          note "A rejected key logs 'is not permitted' or 'denied access' on BOTH ends."
          note "Also check the name: a child registers its own hostname, so '$want'"
          note "must be what that host calls itself, not what you call it."
        fi
      done
    else
      note "set CHILDREN=\"pve ...\" to assert specific hosts are present"
    fi
  fi
fi

if [ "$MODE" = "FullStack" ]; then
  if LB=$(http "http://$MON_HOST:3100/loki/api/v1/labels"); then
    if printf '%s' "$LB" | grep -q '"job"'; then
      ok "loki has a 'job' label -- logs have arrived at least once"
    else
      warn "loki is up but has no 'job' label yet"
      note "no Alloy agent has shipped anything. On each child:"
      note "journalctl -u alloy -n 50   (usually systemd-journal group membership)"
    fi
  else
    warn "could not query loki labels (code $(hcode))"
  fi
fi

# Netdata health must be ENABLED on the parent, or nothing ever alerts.
if [ -n "$ND_INFO" ]; then
  if AL=$(http "http://$MON_HOST:19999/api/v1/alarms?all"); then
    nal=$(json_get "$AL" "len(d.get('alarms',{}))" || echo "")
    if [ -n "$nal" ] && [ "$nal" -gt 0 ] 2>/dev/null; then
      ok "netdata health engine active ($nal alarms defined)"
    else
      bad "netdata reports zero alarms -- health engine is off, nothing will alert"
    fi
  else
    warn "could not read netdata alarms endpoint (code $(hcode))"
  fi
fi

# --------------------------------------------------------------------- summary
printf '\n%s== Summary%s\n' "$B" "$Z"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' \
  "$G" "$PASS" "$Z" "$Y" "$WARN" "$Z" "$R" "$FAIL" "$Z"

if [ "$FAIL" -gt 0 ]; then
  printf '\n  %sSomething is broken.%s Work top-down: a failed layer explains the ones below it.\n' "$R" "$Z"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  printf '\n  %sUsable, with caveats above.%s\n' "$Y" "$Z"
  exit 0
else
  printf '\n  %sAll checks passed.%s\n' "$G" "$Z"
  exit 0
fi

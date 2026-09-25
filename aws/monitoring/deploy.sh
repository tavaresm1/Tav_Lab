#!/usr/bin/env bash
# Deploy the tailnet monitoring node. Run from this directory.
#
#   ./deploy.sh preflight    check tooling, credentials and secrets before deploying
#   ./deploy.sh secrets      create the SSM SecureStrings (once, interactive)
#   ./deploy.sh network      deploy/update the VPC stack
#   ./deploy.sh monitoring   deploy/update the instance stack
#   ./deploy.sh all          secrets check + network + monitoring
#   ./deploy.sh status       show stack status, outputs, and how to reach things
#   ./deploy.sh logs         read the instance bootstrap log from CloudWatch --
#                            works even after a rollback deleted the instance
#   ./deploy.sh diag         collect stack events + bootstrap log + alarm history
#                            into one diag-*.txt file. Runs automatically on a
#                            failed 'monitoring' deploy.
#   ./deploy.sh orphans      list EBS volumes left behind by a rollback/terminate
#   ./deploy.sh destroy      tear both stacks down (asks first)
#
# Env overrides:
#   AWS_REGION          default us-east-1
#   NETWORK_STACK       default mon-network
#   MONITORING_STACK    default mon-node
#   MODE                FullStack | WatchdogOnly   default FullStack
#   INSTANCE_TYPE       default t4g.medium (use t4g.nano for WatchdogOnly)
#   DATA_GB             default 100
#   TS_HOSTNAME         default mon-aws
#   TS_TAG              default tag:monitor
#   ALERT_EMAIL         optional; enables SNS + EC2 status-check alarms
#   ADMIN_USER          optional; named passwordless local admin for Tailscale SSH.
#                       Must ALSO be added to the Tailscale ACL ssh "users" list.
#                       Blank = use the AMI's 'ubuntu' account, which already works.
#   ADMIN_SSH_KEY       optional OpenSSH PUBLIC key for ADMIN_USER. A public key is
#                       not a secret, so unlike TS_KEY/ND_KEY it may be passed here.
#   PUBLIC_IPV4         true | false   default true
#   DISABLE_ROLLBACK    1 = leave a failed stack standing so you can read the
#                       bootstrap log instead of losing it to rollback
#   LOG_GROUP           default /tavlab/monitoring-bootstrap
#   SINCE               default 24h, passed to 'aws logs tail'
#   WATCH               1 (default) = follow the bootstrap log live during deploy

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
NETWORK_STACK="${NETWORK_STACK:-mon-network}"
MONITORING_STACK="${MONITORING_STACK:-mon-node}"
MODE="${MODE:-FullStack}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.medium}"
DATA_GB="${DATA_GB:-100}"
TS_HOSTNAME="${TS_HOSTNAME:-mon-aws}"
TS_TAG="${TS_TAG:-tag:monitor}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"
PUBLIC_IPV4="${PUBLIC_IPV4:-true}"
LOG_GROUP="${LOG_GROUP:-/tavlab/monitoring-bootstrap}"
SINCE="${SINCE:-24h}"

TS_KEY_PARAM=/monitoring/tailscale-authkey
ND_KEY_PARAM=/monitoring/netdata-stream-key
GF_PW_PARAM=/monitoring/grafana-admin-password

AWS="aws --region $AWS_REGION"

# AWS CLI v2 pipes output through 'less' by default, which injects
# ':...skipping...' markers into anything you redirect to a file. That is what
# made the first captured error log unparseable. Never remove this.
export AWS_PAGER=""

die() { echo "error: $*" >&2; exit 1; }
have_param() { $AWS ssm get-parameter --name "$1" >/dev/null 2>&1; }

# Emit one lowercase UUID, or die. Tries several sources and VALIDATES the
# result of each, rather than probing for a binary and trusting it.
#
# Probing is not sufficient, and both failure modes have actually bitten:
#   - Windows: the Microsoft Store puts `python`/`python3` App Execution Alias
#     stubs on PATH. They satisfy `command -v`, then print "Python was not
#     found" and exit non-zero. Output: empty.
#   - Ubuntu: no `python` binary at all since 20.04, only `python3`.
# Either way an EMPTY string reaches `ssm put-parameter`. AWS happens to reject
# it on a length validator, but that is luck, not a safety net -- an empty
# Netdata streaming key would silently accept every child on the tailnet.
#
# The kernel source goes first: present on every Linux, needs no interpreter,
# and cannot half-work. The trailing tr strips the CR that powershell emits;
# a stray CR inside a key corrupts it in ways that are miserable to debug.
gen_uuid() {
  local src u
  for src in kernel uuidgen python3 python powershell; do
    u=""
    case "$src" in
      kernel)  [ -r /proc/sys/kernel/random/uuid ] \
                 && u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) ;;
      uuidgen) u=$(uuidgen 2>/dev/null) ;;
      python3) u=$(python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null) ;;
      python)  u=$(python  -c "import uuid;print(uuid.uuid4())" 2>/dev/null) ;;
      powershell) u=$(powershell -NoProfile -Command \
                      "[guid]::NewGuid().ToString()" 2>/dev/null) ;;
    esac
    u=$(printf '%s' "$u" | tr -d '\r\n ' | tr 'A-Z' 'a-z')
    # 8-4-4-4-12 hex. Deliberately a glob, not a regex: no grep dependency.
    case "$u" in
      ????????-????-????-????-????????????)
        case "$u" in
          *[^0-9a-f-]*) ;;
          *) printf '%s\n' "$u"; return 0 ;;
        esac ;;
    esac
  done
  die "no working UUID source (tried /proc, uuidgen, python3, python, powershell)"
}

cmd_preflight() {
  local fail=0
  echo "== preflight"

  if command -v aws >/dev/null 2>&1; then
    echo "  ok    aws cli: $(aws --version 2>&1 | cut -d' ' -f1)"
  else
    echo "  FAIL  aws cli not on PATH"; fail=1
  fi

  if ident=$($AWS sts get-caller-identity --query Arn --output text 2>/dev/null); then
    echo "  ok    credentials: $ident"
    echo "  ok    region: $AWS_REGION"
  else
    echo "  FAIL  no usable AWS credentials for region $AWS_REGION"; fail=1
  fi

  if u=$(gen_uuid 2>/dev/null); then
    echo "  ok    uuid source available (sample ${u:0:8}...)"
  else
    echo "  FAIL  cannot generate a UUID"; fail=1
  fi

  if command -v session-manager-plugin >/dev/null 2>&1; then
    echo "  ok    session-manager-plugin present (break-glass access works)"
  else
    echo "  WARN  session-manager-plugin missing -- 'aws ssm start-session' will not"
    echo "        work, which is your only way in if Tailscale fails to come up."
    echo "        https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  fi

  for p in "$TS_KEY_PARAM" "$ND_KEY_PARAM"; do
    if have_param "$p"; then echo "  ok    $p exists"
    else echo "  todo  $p missing -- run './deploy.sh secrets'"; fi
  done

  # ADMIN_SSH_KEY goes into the template as a plain CFN parameter, so it lands in
  # stack history and 'describe-stacks' output forever. That is fine for a PUBLIC
  # key and catastrophic for a private one, and the two are one tab-completion
  # apart (id_ed25519 vs id_ed25519.pub). Refuse the private form outright --
  # there is no recovering a key once it is in stack events.
  if [ -n "$ADMIN_SSH_KEY" ]; then
    case "$ADMIN_SSH_KEY" in
      *PRIVATE\ KEY*)
        echo "  FAIL  ADMIN_SSH_KEY looks like a PRIVATE key. It would be stored in"
        echo "        CloudFormation stack history in cleartext. Use the .pub file."
        fail=1 ;;
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *|sk-ecdsa-*\ *)
        echo "  ok    ADMIN_SSH_KEY looks like a public key (${ADMIN_SSH_KEY%% *})" ;;
      *)
        echo "  FAIL  ADMIN_SSH_KEY is not a recognisable OpenSSH public key."
        echo "        Expected the one-line contents of e.g. ~/.ssh/id_ed25519.pub"
        fail=1 ;;
    esac
  fi

  # Tailscale SSH refuses a target user that the ACL does not list, and the
  # failure looks like a plain login rejection rather than a policy problem.
  # Cannot be checked from here -- the ACL lives in the Tailscale console -- so
  # say it out loud instead of letting it be discovered at ssh time.
  if [ -n "$ADMIN_USER" ]; then
    echo "  note  ADMIN_USER=$ADMIN_USER -- add \"$ADMIN_USER\" to the \"users\" list in"
    echo "        the Tailscale ACL ssh block, or 'ssh $ADMIN_USER@$TS_HOSTNAME' is refused."
  fi

  [ "$fail" -eq 0 ] || die "preflight failed; fix the FAIL lines above"
  echo "  preflight passed"
}

cmd_secrets() {
  if have_param "$TS_KEY_PARAM"; then
    echo "$TS_KEY_PARAM already exists -- leaving it alone."
  else
    echo
    echo "Create a Tailscale auth key first:"
    echo "  https://login.tailscale.com/admin/settings/keys"
    echo "  - Reusable: no (one-shot is fine)"
    echo "  - Ephemeral: NO (this node must persist across reboots)"
    echo "  - Tags: $TS_TAG   <-- required, or the key expires in 90 days"
    echo
    read -rsp "Paste the Tailscale auth key (tskey-auth-...): " tskey; echo
    tskey="$(printf '%s' "$tskey" | tr -d '\r\n ')"
    [ -n "$tskey" ] || die "empty auth key"
    case "$tskey" in
      tskey-auth-*) ;;
      *) die "that does not look like an auth key (expected tskey-auth-...)" ;;
    esac
    $AWS ssm put-parameter --name "$TS_KEY_PARAM" --type SecureString \
      --value "$tskey" --description "Tailscale auth key for the monitoring node" >/dev/null
    echo "stored $TS_KEY_PARAM"
  fi

  if have_param "$ND_KEY_PARAM"; then
    echo "$ND_KEY_PARAM already exists -- leaving it alone."
  else
    ndkey="$(gen_uuid | tr -d '\r' | tr 'A-Z' 'a-z')"
    $AWS ssm put-parameter --name "$ND_KEY_PARAM" --type SecureString \
      --value "$ndkey" --description "Netdata streaming API key, shared with home children" >/dev/null
    echo "stored $ND_KEY_PARAM (generated)"
  fi

  echo
  echo "Netdata streaming key -- home nodes need this exact value:"
  $AWS ssm get-parameter --name "$ND_KEY_PARAM" --with-decryption \
    --query Parameter.Value --output text
}

cmd_network() {
  echo ">> deploying $NETWORK_STACK"
  $AWS cloudformation deploy \
    --stack-name "$NETWORK_STACK" \
    --template-file 01-network.yaml \
    --no-fail-on-empty-changeset \
    --tags Project=TavLab Component=monitoring
}

cmd_monitoring() {
  have_param "$TS_KEY_PARAM" || die "$TS_KEY_PARAM missing -- run './deploy.sh secrets' first"
  have_param "$ND_KEY_PARAM" || die "$ND_KEY_PARAM missing -- run './deploy.sh secrets' first"

  # DISABLE_ROLLBACK=1 keeps a failed instance alive so you can read
  # /var/log/monitoring-bootstrap.log instead of watching the evidence get
  # deleted. Remember to delete the stack by hand afterwards.
  local rollback_arg=()
  if [ "${DISABLE_ROLLBACK:-0}" = "1" ]; then
    rollback_arg=(--disable-rollback)
    echo ">> rollback DISABLED -- a failed stack will be left in place for debugging"
  fi

  # Follow the bootstrap log live while CFN blocks. The instance flushes to
  # CloudWatch at every stage boundary, so this shows real progress. The group
  # will not exist on a first-ever deploy, hence the wait loop.
  local tail_pid=""
  if [ "${WATCH:-1}" = "1" ]; then
    (
      for _ in $(seq 1 60); do
        if $AWS logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
             --query 'logGroups[0].logGroupName' --output text 2>/dev/null \
             | grep -q .; then
          $AWS logs tail "$LOG_GROUP" --follow --since 5m 2>/dev/null
          exit 0
        fi
        sleep 10
      done
    ) &
    tail_pid=$!
    echo ">> following $LOG_GROUP live (WATCH=0 to disable)"
  fi

  echo ">> deploying $MONITORING_STACK (mode=$MODE type=$INSTANCE_TYPE data=${DATA_GB}GB)"
  local rc=0
  $AWS cloudformation deploy \
    --stack-name "$MONITORING_STACK" \
    --template-file 02-monitoring.yaml \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    "${rollback_arg[@]+"${rollback_arg[@]}"}" \
    --tags Project=TavLab Component=monitoring \
    --parameter-overrides \
      NetworkStackName="$NETWORK_STACK" \
      DeploymentMode="$MODE" \
      InstanceType="$INSTANCE_TYPE" \
      DataVolumeSizeGb="$DATA_GB" \
      TailscaleHostname="$TS_HOSTNAME" \
      TailscaleTag="$TS_TAG" \
      AssignPublicIpv4="$PUBLIC_IPV4" \
      AlertEmail="$ALERT_EMAIL" \
      AdminUsername="$ADMIN_USER" \
      AdminSshPublicKey="$ADMIN_SSH_KEY" \
      TailscaleAuthKeyParam="$TS_KEY_PARAM" \
      NetdataStreamKeyParam="$ND_KEY_PARAM" \
      GrafanaPasswordParam="$GF_PW_PARAM" \
      BootstrapLogGroupName="$LOG_GROUP" || rc=$?

  if [ -n "$tail_pid" ]; then
    sleep 5   # let the last flushed chunk arrive before we cut the tail off
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
  fi

  if [ "$rc" -ne 0 ]; then
    echo
    echo ">> deploy FAILED (exit $rc) -- collecting diagnostics"
    cmd_diag || true
    return "$rc"
  fi
}

# Collect everything needed to explain a failure into ONE local file, so it can
# be read or handed over without hunting through six consoles. Ordered so the
# verdict is at the top and the raw material below it.
cmd_diag() {
  local out="diag-$(date -u +%Y%m%d-%H%M%SZ).txt"
  {
    echo "# monitoring deploy diagnostics"
    echo "# region=$AWS_REGION stack=$MONITORING_STACK generated=$(date -u +%FT%TZ)"
    echo

    echo "===== 1. stack status"
    $AWS cloudformation describe-stacks --stack-name "$MONITORING_STACK" \
      --query 'Stacks[0].[StackStatus,StackStatusReason]' --output text 2>&1 || true
    echo

    echo "===== 2. why it failed (failure events only, oldest first)"
    $AWS cloudformation describe-stack-events --stack-name "$MONITORING_STACK" \
      --query 'reverse(StackEvents[?contains(ResourceStatus,`FAILED`)].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason])' \
      --output text 2>&1 || true
    echo

    echo "===== 3. bootstrap log from CloudWatch (survives rollback)"
    echo "# look for '=== STAGE:', '=== result=' and '=== failed near line'"
    $AWS logs tail "$LOG_GROUP" --since "$SINCE" 2>&1 || true
    echo

    echo "===== 4. status-check alarm history (did auto-recovery fire?)"
    for a in "$MONITORING_STACK-system-status-failed" \
             "$MONITORING_STACK-instance-status-failed"; do
      echo "--- $a"
      $AWS cloudwatch describe-alarm-history --alarm-name "$a" \
        --history-item-type StateUpdate --max-records 20 \
        --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text 2>&1 || true
    done
    echo

    echo "===== 5. EC2 instance events / recovery actions (last 24h, via CloudTrail)"
    $AWS cloudtrail lookup-events \
      --lookup-attributes AttributeKey=EventName,AttributeValue=RecoverInstance \
      --query 'Events[].[EventTime,Username,CloudTrailEvent]' --output text 2>&1 \
      | head -40 || true
    echo

    echo "===== 6. detached volumes still billing"
    $AWS ec2 describe-volumes --filters Name=status,Values=available \
      --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime]' --output text 2>&1 || true
    echo

    echo "===== 7. full stack event history"
    $AWS cloudformation describe-stack-events --stack-name "$MONITORING_STACK" \
      --query 'reverse(StackEvents[].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason])' \
      --output text 2>&1 || true
  } > "$out" 2>&1

  echo "wrote $out ($(wc -l < "$out" | tr -d ' ') lines)"
  echo
  echo "== verdict (sections 1-2)"
  sed -n '/===== 1/,/===== 3/p' "$out" | head -30
}

# The instance ships /var/log/monitoring-bootstrap.log here on both success and
# failure, so this is the one diagnostic that survives a CREATE_FAILED rollback
# deleting the instance out from under you. One stream per instance id.
cmd_logs() {
  if ! $AWS logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
       --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q .; then
    echo "no log group $LOG_GROUP in $AWS_REGION."
    echo "Either the instance never got as far as installing the AWS CLI, or you"
    echo "deployed with a template older than the CloudWatch shipping change."
    return 1
  fi

  echo "== streams in $LOG_GROUP (newest first)"
  $AWS logs describe-log-streams --log-group-name "$LOG_GROUP" \
    --order-by LastEventTime --descending --max-items 10 \
    --query 'logStreams[].[logStreamName,lastEventTimestamp]' --output table || true

  echo
  echo "== log contents (last $SINCE)"
  echo "   look for '=== result=' and '=== failed near line' -- that is the verdict,"
  echo "   and '=== STAGE:' markers to see how far the bootstrap got."
  $AWS logs tail "$LOG_GROUP" --since "$SINCE"
}

# A rollback terminates the instance, but DataVolumeDeleteOnTermination defaults
# to false, so the 100GB gp3 data volume is left behind -- detached, unused, and
# still billing at ~$0.08/GB-month.
cmd_orphans() {
  echo "== available (detached) EBS volumes in $AWS_REGION"
  $AWS ec2 describe-volumes \
    --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime,Tags[?Key==`Name`].Value|[0]]' \
    --output table

  echo "Anything listed above is detached and billing. Delete with:"
  echo "  aws --region $AWS_REGION ec2 delete-volume --volume-id vol-xxxxxxxx"
  echo "Check the size/date against your monitoring deploy before deleting --"
  echo "this lists every available volume in the region, not just ours."
}

cmd_status() {
  for s in "$NETWORK_STACK" "$MONITORING_STACK"; do
    echo "== $s"
    $AWS cloudformation describe-stacks --stack-name "$s" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "not deployed"
  done
  echo
  echo "== outputs"
  $AWS cloudformation describe-stacks --stack-name "$MONITORING_STACK" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table 2>/dev/null \
    || echo "not deployed"

  local st
  st=$($AWS cloudformation describe-stacks --stack-name "$MONITORING_STACK" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
  case "$st" in
    *FAILED*|*ROLLBACK*)
      echo
      echo ">> $MONITORING_STACK is $st -- read the bootstrap log with:"
      echo "     ./deploy.sh logs"
      echo "   then check for a leftover data volume with:"
      echo "     ./deploy.sh orphans"
      ;;
  esac
}

cmd_destroy() {
  read -rp "Delete $MONITORING_STACK and $NETWORK_STACK in $AWS_REGION? [y/N] " a
  [ "$a" = "y" ] || exit 0
  $AWS cloudformation delete-stack --stack-name "$MONITORING_STACK"
  $AWS cloudformation wait stack-delete-complete --stack-name "$MONITORING_STACK"
  $AWS cloudformation delete-stack --stack-name "$NETWORK_STACK"
  $AWS cloudformation wait stack-delete-complete --stack-name "$NETWORK_STACK"
  echo
  echo "Done. Four things CloudFormation did NOT clean up:"
  echo "  - the /data EBS volume, if DataVolumeDeleteOnTermination was false"
  echo "    -> run './deploy.sh orphans' to find it; it bills until deleted"
  echo "  - the node entry in your Tailscale admin console"
  echo "  - SSM parameters under /monitoring/ (delete by hand if you are finished)"
  echo "  - the $LOG_GROUP CloudWatch group (kept on purpose so post-mortems survive)"
}

case "${1:-}" in
  preflight)  cmd_preflight ;;
  secrets)    cmd_secrets ;;
  network)    cmd_network ;;
  monitoring) cmd_monitoring ;;
  all)        cmd_preflight; cmd_secrets; cmd_network; cmd_monitoring; cmd_status ;;
  status)     cmd_status ;;
  logs)       cmd_logs ;;
  diag)       cmd_diag ;;
  orphans)    cmd_orphans ;;
  destroy)    cmd_destroy ;;
  *)          sed -n '2,30p' "$0"; exit 1 ;;
esac

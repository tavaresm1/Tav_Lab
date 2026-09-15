#!/usr/bin/env bash
# Deploy the tailnet monitoring node. Run from this directory.
#
#   ./deploy.sh preflight    check tooling, credentials and secrets before deploying
#   ./deploy.sh secrets      create the SSM SecureStrings (once, interactive)
#   ./deploy.sh network      deploy/update the VPC stack
#   ./deploy.sh monitoring   deploy/update the instance stack
#   ./deploy.sh all          secrets check + network + monitoring
#   ./deploy.sh status       show stack status, outputs, and how to reach things
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
#   PUBLIC_IPV4         true | false   default true
#   DISABLE_ROLLBACK    1 = leave a failed stack standing so you can read the
#                       bootstrap log instead of losing it to rollback

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
PUBLIC_IPV4="${PUBLIC_IPV4:-true}"

TS_KEY_PARAM=/monitoring/tailscale-authkey
ND_KEY_PARAM=/monitoring/netdata-stream-key
GF_PW_PARAM=/monitoring/grafana-admin-password

AWS="aws --region $AWS_REGION"

die() { echo "error: $*" >&2; exit 1; }
have_param() { $AWS ssm get-parameter --name "$1" >/dev/null 2>&1; }

# Git for Windows ships no uuidgen, so fall back through whatever is present.
# tr -d '\r' matters: powershell emits CRLF and a stray CR would corrupt the key.
gen_uuid() {
  if   command -v uuidgen  >/dev/null 2>&1; then uuidgen
  elif command -v python   >/dev/null 2>&1; then python  -c "import uuid;print(uuid.uuid4())"
  elif command -v python3  >/dev/null 2>&1; then python3 -c "import uuid;print(uuid.uuid4())"
  elif command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -Command "[guid]::NewGuid().ToString()"
  else
    die "no way to generate a UUID (need uuidgen, python, or powershell)"
  fi
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

  echo ">> deploying $MONITORING_STACK (mode=$MODE type=$INSTANCE_TYPE data=${DATA_GB}GB)"
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
      TailscaleAuthKeyParam="$TS_KEY_PARAM" \
      NetdataStreamKeyParam="$ND_KEY_PARAM" \
      GrafanaPasswordParam="$GF_PW_PARAM"
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
}

cmd_destroy() {
  read -rp "Delete $MONITORING_STACK and $NETWORK_STACK in $AWS_REGION? [y/N] " a
  [ "$a" = "y" ] || exit 0
  $AWS cloudformation delete-stack --stack-name "$MONITORING_STACK"
  $AWS cloudformation wait stack-delete-complete --stack-name "$MONITORING_STACK"
  $AWS cloudformation delete-stack --stack-name "$NETWORK_STACK"
  $AWS cloudformation wait stack-delete-complete --stack-name "$NETWORK_STACK"
  echo
  echo "Done. Two things CloudFormation did NOT clean up:"
  echo "  - the /data EBS volume, if DataVolumeDeleteOnTermination was false"
  echo "  - the node entry in your Tailscale admin console"
  echo "  - SSM parameters under /monitoring/ (delete by hand if you are finished)"
}

case "${1:-}" in
  preflight)  cmd_preflight ;;
  secrets)    cmd_secrets ;;
  network)    cmd_network ;;
  monitoring) cmd_monitoring ;;
  all)        cmd_preflight; cmd_secrets; cmd_network; cmd_monitoring; cmd_status ;;
  status)     cmd_status ;;
  destroy)    cmd_destroy ;;
  *)          sed -n '2,24p' "$0"; exit 1 ;;
esac

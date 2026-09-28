#!/usr/bin/env bash
#
# Ask the Govee Platform API what your actual devices can do.
#
# This resolves the one open question that could change the integration choice:
# whether the outdoor (H705x) and TV-backlight (H605x/H66Ax) SKUs really return
# the advanced capabilities, or only basic color. The research round could not
# settle it — Govee's model-list page kept returning HTTP 429.
#
# Usage:
#   GOVEE_API_KEY=xxxx ./check-capabilities.sh
#   ./check-capabilities.sh --raw > devices.json     # full response, for the record
#
# Get a key: Govee Home app -> Profile -> About Us -> Apply for API Key.
#
# Costs one request against a 30 req/min/account limit. Safe to re-run.

set -euo pipefail

API="https://openapi.api.govee.com/router/api/v1/user/devices"

# The four capabilities that separate "max coverage" from "just a dimmer".
WANTED='segmentedColorRgb segmentedBrightness lightScene diyScene snapshot musicMode'

if [[ -z "${GOVEE_API_KEY:-}" ]]; then
  echo "error: GOVEE_API_KEY is not set." >&2
  echo "usage: GOVEE_API_KEY=xxxx $0 [--raw]" >&2
  exit 1
fi

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "error: $cmd is required." >&2; exit 1; }
done

response=$(curl -sS --fail-with-body -w '\n%{http_code}' \
  -H "Govee-API-Key: ${GOVEE_API_KEY}" \
  -H 'Content-Type: application/json' \
  "$API") || true

http_code=$(tail -n1 <<<"$response")
body=$(sed '$d' <<<"$response")

case "$http_code" in
  200) ;;
  401|403) echo "error: HTTP $http_code — key rejected. Check for whitespace in GOVEE_API_KEY." >&2; exit 1 ;;
  429)     echo "error: HTTP 429 — rate limited (30 req/min/account). Wait a minute." >&2; exit 1 ;;
  *)       echo "error: HTTP $http_code" >&2; echo "$body" >&2; exit 1 ;;
esac

if [[ "${1:-}" == "--raw" ]]; then
  jq '.' <<<"$body"
  exit 0
fi

count=$(jq '.data | length' <<<"$body")
echo "Devices returned by the Platform API: $count"
echo

# Per-device capability instances, with the interesting ones called out.
jq -r --arg wanted "$WANTED" '
  ($wanted | split(" ")) as $want
  | .data[]
  | . as $d
  | ([$d.capabilities[].instance] | unique) as $have
  | ($want - ($want - $have)) as $hits
  | "\($d.sku)  \($d.deviceName)",
    "    has:     \($hits | if length == 0 then "(none of the advanced capabilities)" else join(", ") end)",
    "    missing: \(($want - $have) | join(", "))",
    ""
' <<<"$body"

echo "--- Summary by capability ---"
for cap in $WANTED; do
  skus=$(jq -r --arg c "$cap" '
    [ .data[] | select(any(.capabilities[]; .instance == $c)) | .sku ] | unique | join(" ")
  ' <<<"$body")
  printf '%-20s %s\n' "$cap" "${skus:-(no devices)}"
done

cat <<'EOF'

--- How to read this ---
segmentedColorRgb / segmentedBrightness  per-segment control
lightScene / diyScene / snapshot         the app's real scene library
musicMode                                music mode

If your H705x outdoor lights and H605x/H66Ax TV kits appear under
segmentedColorRgb and lightScene, lasswellt/govee-homeassistant is the pick.
If the outdoor lights show "(none of the advanced capabilities)", try
wez/govee2mqtt before concluding the devices cannot do it -- Govee's API is
known to under-report (H7021 reports 15 of 30 real segments).

Devices absent from the list entirely are likely Bluetooth-only: no cloud or LAN
integration can reach them. See SETUP.md.
EOF

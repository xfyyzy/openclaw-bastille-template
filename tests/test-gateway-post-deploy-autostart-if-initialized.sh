#!/bin/sh
set -eu

SCRIPT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/openclaw-jailctl.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Deploy flow should detect gateway init marker before auto-starting.
if ! rg -n --fixed-strings 'service openclaw_gateway check 2>/dev/null' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy gateway init marker discovery"
fi

if ! rg -n --fixed-strings 'bastille cmd "${JAIL_NAME}" test -f "${gateway_init_marker}" >/dev/null 2>&1' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy gateway init marker presence check"
fi

# Deploy flow should only start gateway after marker is present and verify status.
if ! rg -n --fixed-strings 'bastille cmd "${JAIL_NAME}" service openclaw_gateway start >/dev/null 2>&1' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy gateway start attempt"
fi

if ! rg -n --fixed-strings 'bastille cmd "${JAIL_NAME}" service openclaw_gateway status >/dev/null 2>&1' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy gateway status probe"
fi

# Marker missing should be non-fatal and provide next action.
if ! rg -n --fixed-strings 'info: openclaw_gateway init marker not found' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy non-fatal marker-missing hint for gateway"
fi

if ! rg -n --fixed-strings 'service openclaw_gateway init' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing marker-missing recovery command for gateway init"
fi

echo "PASS: deploy flow includes gateway auto-start gated by init marker"

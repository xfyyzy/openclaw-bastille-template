#!/bin/sh
set -eu

SCRIPT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/openclaw-jailctl.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Expect configurable timeout knobs to be wired into curl mirror probe.
if ! rg -n --fixed-strings -- '--connect-timeout "${MIRROR_PROBE_CONNECT_TIMEOUT}"' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing configurable connect-timeout in mirror probe curl command"
fi

if ! rg -n --fixed-strings -- '--max-time "${MIRROR_PROBE_MAX_TIME}"' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing configurable max-time in mirror probe curl command"
fi

# Expect per-step logs so slow probes no longer look stuck.
if ! rg -n --fixed-strings 'mirror probe step:' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing mirror probe step logs"
fi

echo "PASS: mirror probe timeout knobs and step logs detected"

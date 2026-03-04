#!/bin/sh
set -eu

SCRIPT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/openclaw-jailctl.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# 1) Help should advertise the flag.
if ! "$SCRIPT" --help 2>&1 | rg -n --fixed-strings -- '--no-preflight' >/dev/null 2>&1; then
  fail "missing --no-preflight in help output"
fi

# 2) Flag should be rejected for non-deploy actions.
set +e
output=$("$SCRIPT" --preflight --no-preflight 2>&1)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail "--preflight --no-preflight should fail"
fi
if ! printf '%s' "$output" | rg -n --fixed-strings -- '--no-preflight can only be used with --deploy' >/dev/null 2>&1; then
  fail "missing controlled-use error for --no-preflight"
fi

# 3) Script should contain explicit skip path marker.
if ! rg -n --fixed-strings -- 'Skipping preflight checks (--no-preflight).' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing explicit skip-preflight marker"
fi

echo "PASS: --no-preflight control flow detected"

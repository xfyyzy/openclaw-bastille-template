#!/bin/sh
set -eu

SCRIPT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/openclaw-jailctl.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Deploy flow should attempt an idempotent post-template start for SearXNG.
if ! rg -n --fixed-strings 'bastille cmd "${JAIL_NAME}" service openclaw_searxng status >/dev/null 2>&1' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy searxng status probe"
fi

if ! rg -n --fixed-strings 'bastille cmd "${JAIL_NAME}" service openclaw_searxng start >/dev/null 2>&1' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing post-deploy searxng start attempt"
fi

if ! rg -n --fixed-strings 'warning: openclaw_searxng is not running after deploy; continue with manual recovery:' "$SCRIPT" >/dev/null 2>&1; then
  fail "missing non-blocking warning text for searxng startup failure"
fi

echo "PASS: deploy flow includes searxng auto-start with warning-only fallback"

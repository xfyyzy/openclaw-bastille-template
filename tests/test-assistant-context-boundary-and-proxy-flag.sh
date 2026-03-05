#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALL_SCRIPT="${ROOT}/usr/local/libexec/openclaw/install-openclaw.sh"
ASSISTANT_CONTRACT="${ROOT}/JAIL_ASSISTANT_ENV.md"
README_DOC="${ROOT}/README.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Runtime context flag must be generated from deploy-time USE_PROXY.
if ! rg -n --fixed-strings "runtime_context_path='\${OPENCLAW_ETC_DIR}/runtime-context.env'" "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing runtime-context.env path in install-openclaw.sh"
fi

if ! rg -n --fixed-strings 'OPENCLAW_PROXY_ENABLED=' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_PROXY_ENABLED output in install-openclaw.sh"
fi

# Assistant contract should guide proxy behavior using runtime context flag.
if ! rg -n --fixed-strings '/usr/local/etc/openclaw/runtime-context.env' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing runtime-context.env reference in JAIL_ASSISTANT_ENV.md"
fi

if ! rg -n --fixed-strings 'OPENCLAW_PROXY_ENABLED' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_PROXY_ENABLED guidance in JAIL_ASSISTANT_ENV.md"
fi

# README should clarify documentation audience boundary.
if ! rg -n --fixed-strings 'Documentation Audience' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing documentation audience section in README.md"
fi

if ! rg -n --fixed-strings 'JAIL_ASSISTANT_ENV.md' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing assistant contract reference in README.md"
fi

echo "PASS: runtime proxy flag wiring and documentation boundary guidance detected"

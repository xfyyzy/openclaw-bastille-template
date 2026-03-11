#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
BASTILLEFILE="${ROOT}/Bastillefile"
DEPLOY_SCRIPT="${ROOT}/openclaw-jailctl.sh"
LOCAL_BOOT_RC="${ROOT}/usr/local/etc/rc.d/openclaw_local_boot"
README_DOC="${ROOT}/README.md"
ASSISTANT_CONTRACT="${ROOT}/JAIL_ASSISTANT_ENV.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Template must render/chmod/enable the local boot rc service.
if ! rg -n --fixed-strings 'RENDER /usr/local/etc/rc.d/openclaw_local_boot' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "missing Bastillefile render for openclaw_local_boot"
fi

if ! rg -n --fixed-strings '/usr/local/etc/rc.d/openclaw_local_boot' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "missing Bastillefile chmod entry for openclaw_local_boot"
fi

if ! rg -n --fixed-strings 'CMD sysrc openclaw_local_boot_enable=YES' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "missing Bastillefile sysrc enable for openclaw_local_boot"
fi

# Deploy flow must execute local boot hook immediately after apply_template.
if ! rg -n --fixed-strings 'service openclaw_local_boot start' "${DEPLOY_SCRIPT}" >/dev/null 2>&1; then
  fail "missing deploy-time openclaw_local_boot start"
fi

if ! rg -n --fixed-strings 'error: openclaw_local_boot failed after deploy; aborting.' "${DEPLOY_SCRIPT}" >/dev/null 2>&1; then
  fail "missing strict fatal message for deploy-time openclaw_local_boot failure"
fi

# Rc script contract: missing script should skip; execution failure should be fatal.
if ! rg -n --fixed-strings 'name="openclaw_local_boot"' "${LOCAL_BOOT_RC}" >/dev/null 2>&1; then
  fail "missing rc name openclaw_local_boot"
fi

if ! rg -n --fixed-strings 'missing optional hook script; skipping.' "${LOCAL_BOOT_RC}" >/dev/null 2>&1; then
  fail "missing skip message for absent local boot hook script"
fi

if ! rg -n --fixed-strings 'local boot hook failed:' "${LOCAL_BOOT_RC}" >/dev/null 2>&1; then
  fail "missing strict failure message for local boot hook execution"
fi

# Docs must include developer and in-jail assistant guidance for local boot hook.
if ! rg -n --fixed-strings 'openclaw_local_boot' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing openclaw_local_boot guidance in README.md"
fi

if ! rg -n --fixed-strings '/usr/local/etc/openclaw/boot-local.sh' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing boot-local.sh path in README.md"
fi

if ! rg -n --fixed-strings 'openclaw_local_boot' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing openclaw_local_boot guidance in JAIL_ASSISTANT_ENV.md"
fi

if ! rg -n --fixed-strings '/usr/local/etc/openclaw/boot-local.sh' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing boot-local.sh path in JAIL_ASSISTANT_ENV.md"
fi

echo "PASS: local boot hook contract wiring detected"

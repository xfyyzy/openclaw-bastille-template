#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
BASTILLEFILE="${ROOT}/Bastillefile"
DEPLOY_SCRIPT="${ROOT}/openclaw-jailctl.sh"
LOCAL_CRON_RC="${ROOT}/usr/local/etc/rc.d/openclaw_local_cron"
README_DOC="${ROOT}/README.md"
ASSISTANT_CONTRACT="${ROOT}/JAIL_ASSISTANT_ENV.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Template must render/chmod/enable the local cron rc service.
if ! rg -n --fixed-strings 'RENDER /usr/local/etc/rc.d/openclaw_local_cron' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "missing Bastillefile render for openclaw_local_cron"
fi

if ! rg -n --fixed-strings '/usr/local/etc/rc.d/openclaw_local_cron' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "missing Bastillefile chmod entry for openclaw_local_cron"
fi

# local-cron intentionally avoids rc start semantics; do not auto-enable it.
if rg -n --fixed-strings 'CMD sysrc openclaw_local_cron_enable=YES' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "unexpected Bastillefile sysrc enable for openclaw_local_cron"
fi

# Deploy flow must restore local cron immediately after template apply.
if ! rg -n --fixed-strings 'service openclaw_local_cron apply' "${DEPLOY_SCRIPT}" >/dev/null 2>&1; then
  fail "missing deploy-time openclaw_local_cron apply"
fi

if ! rg -n --fixed-strings 'error: openclaw_local_cron failed after deploy; aborting.' "${DEPLOY_SCRIPT}" >/dev/null 2>&1; then
  fail "missing strict fatal message for deploy-time openclaw_local_cron failure"
fi

# Rc script contract: missing persisted crontab should skip; restore failure should be fatal.
if ! rg -n --fixed-strings 'name="openclaw_local_cron"' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing rc name openclaw_local_cron"
fi

if ! rg -n --fixed-strings '/usr/local/etc/openclaw/crontab.local' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing default persisted crontab path in openclaw_local_cron rc"
fi

if ! rg -n --fixed-strings 'missing optional crontab file; skipping.' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing skip message for absent persisted crontab file"
fi

if ! rg -n --fixed-strings 'failed to restore crontab from' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing strict failure message for crontab restore"
fi

# Rc script should expose an apply subcommand as semantic alias of restore action.
if ! rg -n --fixed-strings 'extra_commands="apply"' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing apply extra command in openclaw_local_cron rc"
fi

if ! rg -n --fixed-strings 'apply_cmd="${name}_apply"' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing apply command mapping in openclaw_local_cron rc"
fi

if ! rg -n --fixed-strings 'openclaw_local_cron_apply()' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing openclaw_local_cron_apply handler in rc script"
fi

if ! rg -n --fixed-strings 'start action is disabled; use' "${LOCAL_CRON_RC}" >/dev/null 2>&1; then
  fail "missing explicit start-disabled guidance in rc script"
fi

# Docs must include developer and in-jail assistant guidance for local cron restore.
if ! rg -n --fixed-strings 'service openclaw_local_cron apply' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing openclaw_local_cron apply usage in README.md"
fi

if ! rg -n --fixed-strings 'service openclaw_local_cron apply' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing openclaw_local_cron apply usage in JAIL_ASSISTANT_ENV.md"
fi

if ! rg -n --fixed-strings 'openclaw_local_cron' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing openclaw_local_cron guidance in JAIL_ASSISTANT_ENV.md"
fi

if ! rg -n --fixed-strings '/usr/local/etc/openclaw/crontab.local' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing persisted crontab path in JAIL_ASSISTANT_ENV.md"
fi

if ! rg -n --fixed-strings 'start` is intentionally disabled' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing start-disabled guidance in README.md"
fi

if ! rg -n --fixed-strings 'start` 被显式禁用' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "missing start-disabled guidance in JAIL_ASSISTANT_ENV.md"
fi

echo "PASS: local cron restore contract wiring detected"

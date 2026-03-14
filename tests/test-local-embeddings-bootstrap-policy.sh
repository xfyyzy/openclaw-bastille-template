#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIG_LIB="${ROOT}/lib/config.sh"
JAILCTL="${ROOT}/openclaw-jailctl.sh"
BASTILLEFILE="${ROOT}/Bastillefile"
INSTALL_SCRIPT="${ROOT}/usr/local/libexec/openclaw/install-openclaw.sh"
CONF_EXAMPLE="${ROOT}/openclaw.conf.example"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if ! rg -n --fixed-strings ': "${OPENCLAW_ENABLE_LOCAL_EMBEDDINGS:=yes}"' "${CONFIG_LIB}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_ENABLE_LOCAL_EMBEDDINGS default in lib/config.sh"
fi

if ! rg -n --fixed-strings 'OPENCLAW_ENABLE_LOCAL_EMBEDDINGS = ${OPENCLAW_ENABLE_LOCAL_EMBEDDINGS}' "${JAILCTL}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_ENABLE_LOCAL_EMBEDDINGS in openclaw-jailctl --help output"
fi

if ! rg -n --fixed-strings 'OPENCLAW_ENABLE_LOCAL_EMBEDDINGS=${OPENCLAW_ENABLE_LOCAL_EMBEDDINGS}' "${JAILCTL}" >/dev/null 2>&1; then
  fail "missing template arg forwarding for OPENCLAW_ENABLE_LOCAL_EMBEDDINGS"
fi

if ! rg -n --fixed-strings 'ARG OPENCLAW_ENABLE_LOCAL_EMBEDDINGS=yes' "${BASTILLEFILE}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_ENABLE_LOCAL_EMBEDDINGS Bastillefile arg"
fi

if ! rg -n --fixed-strings ': "${OPENCLAW_ENABLE_LOCAL_EMBEDDINGS:=yes}"' "${CONF_EXAMPLE}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_ENABLE_LOCAL_EMBEDDINGS example config default"
fi

if ! rg -n --fixed-strings "enable_local_embeddings='\${OPENCLAW_ENABLE_LOCAL_EMBEDDINGS}'" "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing OPENCLAW_ENABLE_LOCAL_EMBEDDINGS render variable in install script"
fi

if ! rg -n --fixed-strings 'installing optional local embedding dependency:' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing node-llama-cpp install branch in install script"
fi

if ! rg -n --fixed-strings 'rebuild_pkgs="${rebuild_pkgs} node-llama-cpp"' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing node-llama-cpp rebuild policy in install script"
fi

if ! rg -n --fixed-strings 'Prewarming local memory embeddings via openclaw memory status --deep...' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing deploy-time memory prewarm log in install script"
fi

if ! rg -n --fixed-strings 'maybe_proxy "${openclaw_cmd}" memory status --deep' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing deploy-time memory prewarm command in install script"
fi

if ! rg -n --fixed-strings 'warning: memory prewarm failed (non-fatal); continuing deploy.' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing non-fatal deploy-time prewarm warning path"
fi

echo "PASS: local embeddings bootstrap wiring detected"

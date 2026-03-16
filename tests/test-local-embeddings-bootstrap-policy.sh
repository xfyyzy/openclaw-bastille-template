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

if ! rg -n --fixed-strings 'cfg.agents.defaults.memorySearch.provider = "local";' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing memorySearch.provider local pin in install script"
fi

if ! rg -n --fixed-strings 'cfg.agents.defaults.memorySearch.local.modelPath = "hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf";' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing default local embedding modelPath pin in install script"
fi

if ! rg -n --fixed-strings 'maybe_proxy "${openclaw_cmd}" memory status --deep --json > "${memory_prewarm_status_json}"' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing deploy-time memory prewarm --json command in install script"
fi

if ! rg -n --fixed-strings 'strict local memory prewarm validation failed; aborting deploy.' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing strict local prewarm semantic validation failure path"
fi

if ! rg -n --fixed-strings 'const normalized = raw.replace(/\r/g, "\n");' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing noisy-output normalization before memory status JSON parse"
fi

if ! rg -n --fixed-strings 'for (let i = 0; i < normalized.length; i++) {' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing fallback scan for embedded JSON payload in prewarm output"
fi

if ! rg -n --fixed-strings 'error: memory prewarm failed; aborting deploy.' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing fatal deploy-time prewarm error path"
fi

if rg -n --fixed-strings 'memory prewarm failed (non-fatal)' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "deploy-time prewarm must not be non-fatal"
fi

echo "PASS: local embeddings bootstrap wiring detected"

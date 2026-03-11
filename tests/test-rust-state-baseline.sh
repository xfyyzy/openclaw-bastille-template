#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WRAPPER="${ROOT}/usr/local/bin/openclaw"
GATEWAY_RC="${ROOT}/usr/local/etc/rc.d/openclaw_gateway"
INSTALL_SCRIPT="${ROOT}/usr/local/libexec/openclaw/install-openclaw.sh"
LEGACY_DEFAULTS="${ROOT}/usr/local/share/openclaw/defaults/legacy-home-paths.conf"
LEGACY_HELPER="${ROOT}/usr/local/libexec/openclaw/prepare-stateful-home.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Wrapper must export Rust state baseline.
if ! rg -n --fixed-strings "export CARGO_HOME='\${OPENCLAW_STATE_DIR}/cargo'" "${WRAPPER}" >/dev/null 2>&1; then
  fail "missing CARGO_HOME baseline in openclaw wrapper"
fi

if ! rg -n --fixed-strings "export RUSTUP_HOME='\${OPENCLAW_STATE_DIR}/rustup'" "${WRAPPER}" >/dev/null 2>&1; then
  fail "missing RUSTUP_HOME baseline in openclaw wrapper"
fi

if ! rg -n --fixed-strings "export SCCACHE_DIR='\${OPENCLAW_STATE_DIR}/sccache'" "${WRAPPER}" >/dev/null 2>&1; then
  fail "missing SCCACHE_DIR baseline in openclaw wrapper"
fi

if ! rg -n --fixed-strings 'export PATH="${CARGO_HOME}/bin:${PATH}"' "${WRAPPER}" >/dev/null 2>&1; then
  fail "missing CARGO_HOME/bin PATH prepend in openclaw wrapper"
fi

# Gateway service environment should carry the same baseline.
if ! rg -n --fixed-strings ': "${openclaw_gateway_cargo_home:=${openclaw_gateway_state_dir}/cargo}"' "${GATEWAY_RC}" >/dev/null 2>&1; then
  fail "missing cargo_home rc default in gateway service"
fi

if ! rg -n --fixed-strings ': "${openclaw_gateway_rustup_home:=${openclaw_gateway_state_dir}/rustup}"' "${GATEWAY_RC}" >/dev/null 2>&1; then
  fail "missing rustup_home rc default in gateway service"
fi

if ! rg -n --fixed-strings ': "${openclaw_gateway_sccache_dir:=${openclaw_gateway_state_dir}/sccache}"' "${GATEWAY_RC}" >/dev/null 2>&1; then
  fail "missing sccache_dir rc default in gateway service"
fi

if ! rg -n --fixed-strings 'export PATH="${openclaw_gateway_cargo_home}/bin:${PATH}"' "${GATEWAY_RC}" >/dev/null 2>&1; then
  fail "missing cargo PATH prepend in gateway service"
fi

# Install phase should ensure directories exist in persisted state.
if ! rg -n --fixed-strings 'install -d -m 0700 "${state_dir}/cargo" "${state_dir}/rustup" "${state_dir}/sccache"' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing rust state directory creation in install-openclaw.sh"
fi

# Legacy HOME defaults should no longer carry cargo/rustup once dedicated state roots exist.
if rg -n --fixed-strings '.cargo' "${LEGACY_DEFAULTS}" >/dev/null 2>&1; then
  fail "legacy defaults should not include .cargo"
fi

if rg -n --fixed-strings '.rustup' "${LEGACY_DEFAULTS}" >/dev/null 2>&1; then
  fail "legacy defaults should not include .rustup"
fi

if rg -n --fixed-strings '.cargo' "${LEGACY_HELPER}" >/dev/null 2>&1; then
  fail "legacy helper fallback should not include .cargo"
fi

if rg -n --fixed-strings '.rustup' "${LEGACY_HELPER}" >/dev/null 2>&1; then
  fail "legacy helper fallback should not include .rustup"
fi

echo "PASS: rust state baseline wiring detected"

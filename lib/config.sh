#!/bin/sh
# Unified configuration loader for openclaw-bastille-template.
#
# Load priority (highest wins):
#   1. Environment variables (already set before this script runs)
#   2. openclaw.conf file (user overrides)
#   3. In-code defaults below (author's environment)
#
# Usage: source this file from any project script.
#   CONFIG_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "${CONFIG_ROOT}/lib/config.sh"
# Or from a subdirectory:
#   CONFIG_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
#   . "${CONFIG_ROOT}/lib/config.sh"

# --- Locate project root and config file ---

# CONFIG_ROOT must be set by the sourcing script to the project root directory.
if [ -z "${CONFIG_ROOT:-}" ]; then
  echo "lib/config.sh: CONFIG_ROOT is not set. Set it to the project root before sourcing." >&2
  exit 1
fi

# --- Source user config file first (if it exists) ---
# Config file values override defaults but are overridden by env vars.
# This works because env vars are already set in the shell environment,
# and the config file uses plain VAR="val" assignments which only take
# effect if the variable is not already exported by the caller.

_conf_file="${OPENCLAW_CONF:-${CONFIG_ROOT}/openclaw.conf}"
if [ -f "${_conf_file}" ]; then
  # shellcheck disable=SC1090
  . "${_conf_file}"
fi
unset _conf_file

# --- Apply defaults (only for variables still unset) ---

# Core jail settings
: "${JAIL_NAME:=openclaw}"
: "${RELEASE:=15.0-RELEASE}"
: "${JAIL_IP:=192.168.88.88/24}"
: "${BRIDGE_IF:=vm-public}"

# Package source: local | remote | mixed | mirror | mixed-mirror
: "${PKG_SOURCE:=local}"
: "${LOCAL_PKG_REPO:=/usr/local/poudriere/data/packages/150amd64-2026Q1}"

# Mirror source selection (used when PKG_SOURCE=mirror or mixed-mirror).
# PKG_MIRROR_PRESET values:
#   official - pkg.freebsd.org (recommended default)
#   aliyun   - mirrors.aliyun.com
#   ustc     - mirrors.ustc.edu.cn
#   nju      - mirrors.nju.edu.cn
#   custom   - use PKG_MIRROR_URL as-is
: "${PKG_MIRROR_PRESET:=official}"
: "${PKG_MIRROR_URL:=}"

# Optional fallback mirror URLs, comma-separated.
# Example:
#   PKG_MIRROR_FALLBACKS="https://mirrors.aliyun.com/freebsd-pkg,https://pkg.freebsd.org"
: "${PKG_MIRROR_FALLBACKS:=}"

case "${PKG_MIRROR_PRESET}" in
  official) _pkg_mirror_preset_url='https://pkg.freebsd.org' ;;
  aliyun)   _pkg_mirror_preset_url='https://mirrors.aliyun.com/freebsd-pkg' ;;
  ustc)     _pkg_mirror_preset_url='https://mirrors.ustc.edu.cn/freebsd-pkg' ;;
  nju)      _pkg_mirror_preset_url='https://mirrors.nju.edu.cn/freebsd-pkg' ;;
  custom)   _pkg_mirror_preset_url='' ;;
  *)        _pkg_mirror_preset_url='' ;;
esac

if [ -z "${PKG_MIRROR_URL}" ] && [ -n "${_pkg_mirror_preset_url}" ]; then
  PKG_MIRROR_URL="${_pkg_mirror_preset_url}"
fi
unset _pkg_mirror_preset_url

# Mirror ABI probe target used by preflight health checks.
_release_major="${RELEASE%%.*}"
_release_major="${_release_major%%-*}"
_host_arch=$(uname -m 2>/dev/null || echo amd64)
case "${_host_arch}" in
  amd64|i386|aarch64|armv7|armv6|riscv64) _pkg_arch="${_host_arch}" ;;
  arm64) _pkg_arch='aarch64' ;;
  *) _pkg_arch='amd64' ;;
esac
: "${PKG_ABI:=FreeBSD:${_release_major}:${_pkg_arch}}"
unset _release_major _host_arch _pkg_arch

# Mirror probe networking timeout knobs (seconds).
# Used by host-side preflight mirror health checks.
: "${MIRROR_PROBE_CONNECT_TIMEOUT:=10}"
: "${MIRROR_PROBE_MAX_TIME:=60}"

# Network proxy: yes | no
: "${USE_PROXY:=yes}"
: "${PROXYCHAINS_CONF_HOST:=/usr/local/etc/proxychains.conf}"

# Software versions
: "${PYTHON_VERSION:=3.11}"
: "${NODE_MAJOR:=25}"

# Host-side persistent directories
: "${HOST_CONFIG_DIR:=/usr/local/etc/openclaw}"
: "${HOST_STATE_DIR:=/var/db/openclaw/state}"
: "${HOST_WORKSPACE_DIR:=/var/db/openclaw/workspace}"
: "${HOST_DATA_DIR:=/var/db/openclaw/data}"

# Assistant context exposure inside jail.
# Default profile: curated snapshot enabled, live repo mount disabled.
: "${OPENCLAW_CONTEXT_SNAPSHOT_ENABLE:=yes}"
: "${OPENCLAW_CONTEXT_SNAPSHOT_DIR:=/usr/local/share/openclaw/context/template-snapshot}"
: "${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE:=no}"
: "${OPENCLAW_CONTEXT_REPO_HOST:=${CONFIG_ROOT}}"
: "${OPENCLAW_CONTEXT_REPO_DIR:=/usr/local/share/openclaw/context/repo-live}"

# ZFS (only used by openclaw-zfs-datasets.sh)
: "${ZPOOL_NAME:=zroot}"

# OpenClaw
: "${OPENCLAW_NPM_SPEC:=openclaw@latest}"

# Package list file (empty = auto-detect)
: "${PKGLIST_FILE:=}"

# --- Derived values ---

# Port origins and binary names from version config
_pyver_nodot=$(printf '%s' "${PYTHON_VERSION}" | tr -d '.')
PYTHON_PORT="lang/python${_pyver_nodot}"
NODE_PORT="www/node${NODE_MAJOR}"
PYTHON_BIN="python${PYTHON_VERSION}"
unset _pyver_nodot

# Bastille prefix (auto-detect from bastille.conf if available)
if [ -z "${BASTILLE_PREFIX:-}" ]; then
  _bastille_conf="/usr/local/etc/bastille/bastille.conf"
  if [ -f "${_bastille_conf}" ]; then
    BASTILLE_PREFIX=$(
      # shellcheck disable=SC1090
      . "${_bastille_conf}" 2>/dev/null && printf '%s' "${bastille_prefix:-}" || true
    )
  fi
  : "${BASTILLE_PREFIX:=/usr/local/bastille}"
  unset _bastille_conf
fi

# Template root and jail directory
: "${TEMPLATE_ROOT:=${BASTILLE_PREFIX}/templates/local/openclaw}"
JAIL_DIR="${BASTILLE_PREFIX}/jails/${JAIL_NAME}"

# Template name: derived from TEMPLATE_ROOT relative to BASTILLE_PREFIX/templates/
_tpl_base="${BASTILLE_PREFIX}/templates/"
TEMPLATE_NAME="${TEMPLATE_ROOT#"${_tpl_base}"}"
unset _tpl_base

# Bootstrap origins: auto-derived from version config and USE_PROXY.
if [ -z "${BOOTSTRAP_ORIGINS:-}" ]; then
  BOOTSTRAP_ORIGINS="ports-mgmt/pkg"
  if [ "${USE_PROXY}" = "yes" ]; then
    BOOTSTRAP_ORIGINS="${BOOTSTRAP_ORIGINS} net/proxychains-ng"
  fi
  BOOTSTRAP_ORIGINS="${BOOTSTRAP_ORIGINS} ${PYTHON_PORT} ${NODE_PORT}"
fi

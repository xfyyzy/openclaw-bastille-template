#!/bin/sh
set -eu

CONFIG_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "${CONFIG_ROOT}/lib/config.sh"

# Auto-detect pkglist file if not explicitly configured.
if [ -z "${PKGLIST_FILE}" ]; then
  for _f in "${CONFIG_ROOT}"/pkglist/*.pkglist; do
    if [ -f "${_f}" ]; then
      PKGLIST_FILE="${_f}"
      break
    fi
  done
  unset _f
fi

# --- CLI ---

MODE="deploy"
MODE_EXPLICIT=0
SKIP_PREFLIGHT=0
SELECTED_PKG_MIRROR_URL="${PKG_MIRROR_URL}"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") [--deploy|--preflight|--stop|--destroy] [--no-preflight] [--help]

Manage lifecycle of jail '${JAIL_NAME}' using current configuration.

Options:
  --deploy      Build/apply template and deploy fresh jail (default)
  --preflight   Run prerequisite checks only (no deployment)
  --stop        Stop existing jail only (no destroy)
  --destroy     Stop and destroy existing jail
  --no-preflight  Skip preflight checks (deploy mode only; risky)
  --help, -h    Show this help and current configuration

Configuration (openclaw.conf or environment variables):
  JAIL_NAME         = ${JAIL_NAME}
  RELEASE           = ${RELEASE}
  JAIL_IP           = ${JAIL_IP}
  BRIDGE_IF         = ${BRIDGE_IF}
  PKG_SOURCE        = ${PKG_SOURCE}
  USE_PROXY         = ${USE_PROXY}
  LOCAL_PKG_REPO    = ${LOCAL_PKG_REPO}
  PKG_MIRROR_PRESET = ${PKG_MIRROR_PRESET}
  PKG_MIRROR_URL    = ${PKG_MIRROR_URL}
  PKG_MIRROR_FALLBACKS = ${PKG_MIRROR_FALLBACKS:-<none>}
  PKG_ABI           = ${PKG_ABI}
  MIRROR_PROBE_CONNECT_TIMEOUT = ${MIRROR_PROBE_CONNECT_TIMEOUT}
  MIRROR_PROBE_MAX_TIME = ${MIRROR_PROBE_MAX_TIME}
  PROXYCHAINS_CONF_HOST = ${PROXYCHAINS_CONF_HOST}
  OPENCLAW_NPM_SPEC = ${OPENCLAW_NPM_SPEC}
  PYTHON_VERSION    = ${PYTHON_VERSION}
  NODE_MAJOR        = ${NODE_MAJOR}
  HOST_CONFIG_DIR   = ${HOST_CONFIG_DIR}
  HOST_STATE_DIR    = ${HOST_STATE_DIR}
  HOST_WORKSPACE_DIR= ${HOST_WORKSPACE_DIR}
  HOST_DATA_DIR     = ${HOST_DATA_DIR}
  OPENCLAW_CONTEXT_SNAPSHOT_ENABLE = ${OPENCLAW_CONTEXT_SNAPSHOT_ENABLE}
  OPENCLAW_CONTEXT_SNAPSHOT_DIR    = ${OPENCLAW_CONTEXT_SNAPSHOT_DIR}
  OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE = ${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}
  OPENCLAW_CONTEXT_REPO_HOST       = ${OPENCLAW_CONTEXT_REPO_HOST}
  OPENCLAW_CONTEXT_REPO_DIR        = ${OPENCLAW_CONTEXT_REPO_DIR}
  BASTILLE_PREFIX   = ${BASTILLE_PREFIX}
  TEMPLATE_ROOT     = ${TEMPLATE_ROOT}
  PKGLIST_FILE      = ${PKGLIST_FILE:-<auto-detect>}

Derived:
  JAIL_DIR          = ${JAIL_DIR}
  TEMPLATE_NAME     = ${TEMPLATE_NAME}
  PYTHON_PORT       = ${PYTHON_PORT}
  NODE_PORT         = ${NODE_PORT}
  BOOTSTRAP_ORIGINS = ${BOOTSTRAP_ORIGINS}

See openclaw.conf.example for full documentation.
USAGE
}

set_mode() {
  _candidate="$1"
  if [ "${MODE_EXPLICIT}" -eq 1 ] && [ "${MODE}" != "${_candidate}" ]; then
    echo "conflicting action options: --${MODE} and --${_candidate}" >&2
    usage >&2
    exit 1
  fi
  MODE="${_candidate}"
  MODE_EXPLICIT=1
}

for _arg in "$@"; do
  case "${_arg}" in
    --deploy)    set_mode "deploy" ;;
    --preflight) set_mode "preflight" ;;
    --stop)      set_mode "stop" ;;
    --destroy)   set_mode "destroy" ;;
    --no-preflight) SKIP_PREFLIGHT=1 ;;
    --help|-h)   usage; exit 0 ;;
    *)           echo "unknown argument: ${_arg}" >&2; usage >&2; exit 1 ;;
  esac
done
unset _arg

if [ "${SKIP_PREFLIGHT}" -eq 1 ] && [ "${MODE}" != "deploy" ]; then
  echo "--no-preflight can only be used with --deploy" >&2
  exit 1
fi

# --- Preflight checks ---

preflight_ok=0

# Pick the available downloader for mirror probes.
mirror_download_tool() {
  if command -v curl >/dev/null 2>&1; then
    printf '%s\n' "curl"
    return 0
  fi
  if command -v fetch >/dev/null 2>&1; then
    printf '%s\n' "fetch"
    return 0
  fi
  return 1
}

is_positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

mirror_probe_log() {
  echo "mirror probe step: $*"
}

# Download URL to file path.
download_to_file() {
  _url="$1"
  _out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout "${MIRROR_PROBE_CONNECT_TIMEOUT}" --max-time "${MIRROR_PROBE_MAX_TIME}" -o "${_out}" "${_url}"
    return 0
  fi
  if command -v fetch >/dev/null 2>&1; then
    fetch -q -T "${MIRROR_PROBE_MAX_TIME}" -o "${_out}" "${_url}"
    return 0
  fi
  return 127
}

# Extract a package path from packagesite metadata by origin.
packagesite_pkg_path() {
  _packagesite_pkg="$1"
  _origin="$2"
  tar -xOf "${_packagesite_pkg}" packagesite.yaml 2>/dev/null \
    | awk -v wanted="\"origin\":\"${_origin}\"" '
        index($0, wanted) {
          if (match($0, /"path":"[^"]+"/)) {
            print substr($0, RSTART + 8, RLENGTH - 9)
            exit
          }
        }
      '
}

# Probe one mirror candidate for metadata/package consistency.
check_mirror_candidate() {
  _base="${1%/}"
  _site_tmp=$(mktemp -t openclaw-mirror-site.XXXXXX)
  _pkg_tmp=$(mktemp -t openclaw-mirror-pkg.XXXXXX)
  _abi_slash=$(printf '%s' "${PKG_ABI}" | tr ':' '/')
  _relpath=''

  for _candidate_rel in "${PKG_ABI}/quarterly" "${_abi_slash}/quarterly"; do
    mirror_probe_log "try packagesite ${_base}/${_candidate_rel}/packagesite.pkg"
    if download_to_file "${_base}/${_candidate_rel}/packagesite.pkg" "${_site_tmp}" >/dev/null 2>&1; then
      mirror_probe_log "packagesite matched ABI path ${_candidate_rel}"
      _relpath="${_candidate_rel}"
      break
    fi
  done

  if [ -z "${_relpath}" ]; then
    mirror_probe_log "packagesite probe failed for candidate ${_base}"
    rm -f "${_site_tmp}" "${_pkg_tmp}"
    return 1
  fi

  _required_origins='ports-mgmt/pkg'
  if [ "${USE_PROXY}" = "yes" ]; then
    _required_origins="${_required_origins} net/proxychains-ng"
  fi

  # shellcheck disable=SC2086
  for _origin in ${_required_origins}; do
    mirror_probe_log "resolve origin ${_origin} from packagesite"
    _pkg_rel=$(packagesite_pkg_path "${_site_tmp}" "${_origin}" || true)
    if [ -z "${_pkg_rel}" ]; then
      mirror_probe_log "origin missing in packagesite: ${_origin}"
      rm -f "${_site_tmp}" "${_pkg_tmp}"
      return 1
    fi
    mirror_probe_log "download package ${_base}/${_relpath}/${_pkg_rel}"
    if ! download_to_file "${_base}/${_relpath}/${_pkg_rel}" "${_pkg_tmp}" >/dev/null 2>&1; then
      mirror_probe_log "package download failed for origin ${_origin}"
      rm -f "${_site_tmp}" "${_pkg_tmp}"
      return 1
    fi
  done

  mirror_probe_log "candidate healthy: ${_base}"
  rm -f "${_site_tmp}" "${_pkg_tmp}"
  return 0
}

# Pick the first healthy mirror from primary + fallback list.
select_healthy_mirror() {
  _candidates_file=$(mktemp -t openclaw-mirror-candidates.XXXXXX)
  {
    printf '%s\n' "${PKG_MIRROR_URL}"
    printf '%s' "${PKG_MIRROR_FALLBACKS}" | tr ',' '\n'
  } | awk '
    {
      gsub(/^[[:space:]]+/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
    }
    length($0) > 0 && !seen[$0]++ { print $0 }
  ' > "${_candidates_file}"

  _selected=''
  while IFS= read -r _candidate; do
    [ -n "${_candidate}" ] || continue
    echo "mirror probe: ${_candidate}"
    if check_mirror_candidate "${_candidate}"; then
      _selected="${_candidate}"
      break
    fi
    echo "warning: mirror candidate unhealthy: ${_candidate}" >&2
  done < "${_candidates_file}"

  rm -f "${_candidates_file}"

  if [ -n "${_selected}" ]; then
    SELECTED_PKG_MIRROR_URL="${_selected}"
    return 0
  fi
  return 1
}

preflight() {
  _errors=0

  # Root check
  if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] not running as root" >&2
    echo "       -> run with sudo or as root" >&2
    _errors=$((_errors + 1))
  else
    echo "[ OK ] running as root"
  fi

  # Input validation
  case "${JAIL_NAME}" in
    [a-zA-Z0-9]*)
      case "${JAIL_NAME}" in
        *[!a-zA-Z0-9_-]*)
          echo "[FAIL] JAIL_NAME contains invalid characters: ${JAIL_NAME}" >&2
          echo "       -> use only letters, digits, hyphens, underscores" >&2
          _errors=$((_errors + 1))
          ;;
        *)
          echo "[ OK ] JAIL_NAME = ${JAIL_NAME}"
          ;;
      esac
      ;;
    *)
      echo "[FAIL] JAIL_NAME must start with a letter or digit: ${JAIL_NAME}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  case "${PKG_SOURCE}" in
    local|remote|mixed|mirror|mixed-mirror)
      echo "[ OK ] PKG_SOURCE = ${PKG_SOURCE}"
      ;;
    *)
      echo "[FAIL] PKG_SOURCE must be local, remote, mixed, mirror, or mixed-mirror: ${PKG_SOURCE}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  case "${USE_PROXY}" in
    yes|no)
      echo "[ OK ] USE_PROXY = ${USE_PROXY}"
      ;;
    *)
      echo "[FAIL] USE_PROXY must be yes or no: ${USE_PROXY}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  case "${OPENCLAW_CONTEXT_SNAPSHOT_ENABLE}" in
    yes|no)
      echo "[ OK ] OPENCLAW_CONTEXT_SNAPSHOT_ENABLE = ${OPENCLAW_CONTEXT_SNAPSHOT_ENABLE}"
      ;;
    *)
      echo "[FAIL] OPENCLAW_CONTEXT_SNAPSHOT_ENABLE must be yes or no: ${OPENCLAW_CONTEXT_SNAPSHOT_ENABLE}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  case "${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}" in
    yes|no)
      echo "[ OK ] OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE = ${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}"
      ;;
    *)
      echo "[FAIL] OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE must be yes or no: ${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  case "${OPENCLAW_CONTEXT_SNAPSHOT_DIR}" in
    /*)
      echo "[ OK ] OPENCLAW_CONTEXT_SNAPSHOT_DIR = ${OPENCLAW_CONTEXT_SNAPSHOT_DIR}"
      ;;
    *)
      echo "[FAIL] OPENCLAW_CONTEXT_SNAPSHOT_DIR must be an absolute jail path: ${OPENCLAW_CONTEXT_SNAPSHOT_DIR}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  case "${OPENCLAW_CONTEXT_REPO_DIR}" in
    /*)
      echo "[ OK ] OPENCLAW_CONTEXT_REPO_DIR = ${OPENCLAW_CONTEXT_REPO_DIR}"
      ;;
    *)
      echo "[FAIL] OPENCLAW_CONTEXT_REPO_DIR must be an absolute jail path: ${OPENCLAW_CONTEXT_REPO_DIR}" >&2
      _errors=$((_errors + 1))
      ;;
  esac

  if [ "${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}" = "yes" ]; then
    case "${OPENCLAW_CONTEXT_REPO_HOST}" in
      /*)
        if [ -d "${OPENCLAW_CONTEXT_REPO_HOST}" ]; then
          echo "[ OK ] OPENCLAW_CONTEXT_REPO_HOST = ${OPENCLAW_CONTEXT_REPO_HOST}"
        else
          echo "[FAIL] OPENCLAW_CONTEXT_REPO_HOST is not a directory: ${OPENCLAW_CONTEXT_REPO_HOST}" >&2
          _errors=$((_errors + 1))
        fi
        ;;
      *)
        echo "[FAIL] OPENCLAW_CONTEXT_REPO_HOST must be an absolute host path when live mount is enabled: ${OPENCLAW_CONTEXT_REPO_HOST}" >&2
        _errors=$((_errors + 1))
        ;;
    esac
  fi

  # Incompatible combination: proxy requires proxychains-ng which must be
  # installed via pkg, but pkg itself needs proxy to reach FreeBSD remote repos.
  if [ "${USE_PROXY}" = "yes" ] && [ "${PKG_SOURCE}" = "remote" ]; then
    echo "[FAIL] USE_PROXY=yes is incompatible with PKG_SOURCE=remote" >&2
    echo "       -> use PKG_SOURCE=mirror or mixed-mirror for restricted networks" >&2
    _errors=$((_errors + 1))
  fi

  # Mirror configuration and health checks (mirror/mixed-mirror only)
  case "${PKG_SOURCE}" in
    mirror|mixed-mirror)
      case "${PKG_MIRROR_PRESET}" in
        official|aliyun|ustc|nju|custom)
          echo "[ OK ] PKG_MIRROR_PRESET = ${PKG_MIRROR_PRESET}"
          ;;
        *)
          echo "[FAIL] PKG_MIRROR_PRESET is invalid: ${PKG_MIRROR_PRESET}" >&2
          echo "       -> choose one of: official, aliyun, ustc, nju, custom" >&2
          _errors=$((_errors + 1))
          ;;
      esac

      if [ -n "${PKG_MIRROR_URL}" ]; then
        echo "[ OK ] PKG_MIRROR_URL = ${PKG_MIRROR_URL}"
      else
        echo "[FAIL] PKG_MIRROR_URL is empty (required for PKG_SOURCE=${PKG_SOURCE})" >&2
        echo "       -> set PKG_MIRROR_PRESET or PKG_MIRROR_URL explicitly" >&2
        _errors=$((_errors + 1))
      fi

      if [ -n "${PKG_MIRROR_FALLBACKS}" ]; then
        echo "[ OK ] PKG_MIRROR_FALLBACKS = ${PKG_MIRROR_FALLBACKS}"
      else
        echo "[ OK ] PKG_MIRROR_FALLBACKS = <none>"
      fi

      _probe_timeout_valid=1
      if is_positive_integer "${MIRROR_PROBE_CONNECT_TIMEOUT}"; then
        echo "[ OK ] MIRROR_PROBE_CONNECT_TIMEOUT = ${MIRROR_PROBE_CONNECT_TIMEOUT}"
      else
        echo "[FAIL] MIRROR_PROBE_CONNECT_TIMEOUT must be a positive integer: ${MIRROR_PROBE_CONNECT_TIMEOUT}" >&2
        _errors=$((_errors + 1))
        _probe_timeout_valid=0
      fi

      if is_positive_integer "${MIRROR_PROBE_MAX_TIME}"; then
        echo "[ OK ] MIRROR_PROBE_MAX_TIME = ${MIRROR_PROBE_MAX_TIME}"
      else
        echo "[FAIL] MIRROR_PROBE_MAX_TIME must be a positive integer: ${MIRROR_PROBE_MAX_TIME}" >&2
        _errors=$((_errors + 1))
        _probe_timeout_valid=0
      fi

      if [ "${_probe_timeout_valid}" -eq 1 ] && [ "${MIRROR_PROBE_CONNECT_TIMEOUT}" -gt "${MIRROR_PROBE_MAX_TIME}" ]; then
        echo "[FAIL] MIRROR_PROBE_CONNECT_TIMEOUT cannot exceed MIRROR_PROBE_MAX_TIME" >&2
        echo "       -> set connect timeout <= max transfer time" >&2
        _errors=$((_errors + 1))
        _probe_timeout_valid=0
      fi

      if _tool=$(mirror_download_tool); then
        echo "[ OK ] mirror probe downloader = ${_tool}"
      else
        echo "[FAIL] mirror probe requires curl or fetch on host" >&2
        echo "       -> install curl, or ensure FreeBSD fetch is available" >&2
        _errors=$((_errors + 1))
      fi

      if [ -n "${PKG_MIRROR_URL}" ] && mirror_download_tool >/dev/null 2>&1 && [ "${_probe_timeout_valid}" -eq 1 ]; then
        if select_healthy_mirror; then
          echo "[ OK ] selected pkg mirror = ${SELECTED_PKG_MIRROR_URL}"
        else
          echo "[FAIL] no healthy pkg mirror candidate found" >&2
          echo "       -> checked primary + fallbacks against packagesite/bootstrap package consistency" >&2
          _errors=$((_errors + 1))
        fi
      fi
      ;;
  esac

  # bastille
  if command -v bastille >/dev/null 2>&1; then
    echo "[ OK ] bastille is installed"
  else
    echo "[FAIL] bastille is not installed" >&2
    echo "       -> pkg install bastille" >&2
    _errors=$((_errors + 1))
  fi

  # bastille.conf
  if [ -f "/usr/local/etc/bastille/bastille.conf" ]; then
    echo "[ OK ] bastille.conf exists"
  else
    echo "[FAIL] bastille.conf not found at /usr/local/etc/bastille/bastille.conf" >&2
    echo "       -> configure bastille: see https://bastillebsd.org/getting-started/" >&2
    _errors=$((_errors + 1))
  fi

  # VNET kernel support
  if sysctl -n kern.features.vimage >/dev/null 2>&1; then
    echo "[ OK ] VNET/VIMAGE kernel support available"
  else
    echo "[FAIL] VNET/VIMAGE kernel support not available" >&2
    echo "       -> requires GENERIC-VIMAGE kernel or custom kernel with 'options VIMAGE'" >&2
    _errors=$((_errors + 1))
  fi

  # Bridge interface
  if ifconfig "${BRIDGE_IF}" >/dev/null 2>&1; then
    echo "[ OK ] bridge interface ${BRIDGE_IF} exists"
  else
    echo "[FAIL] bridge interface ${BRIDGE_IF} does not exist" >&2
    echo "       -> create it: ifconfig bridge create && ifconfig bridge0 name ${BRIDGE_IF} && ifconfig ${BRIDGE_IF} up" >&2
    _errors=$((_errors + 1))
  fi

  # Release bootstrap
  if command -v bastille >/dev/null 2>&1; then
    if bastille list releases 2>/dev/null | grep -qF "${RELEASE}"; then
      echo "[ OK ] release ${RELEASE} is bootstrapped"
    else
      echo "[FAIL] release ${RELEASE} is not bootstrapped" >&2
      echo "       -> bastille bootstrap ${RELEASE}" >&2
      _errors=$((_errors + 1))
    fi
  fi

  # Local pkg repo (only for local/mixed/mixed-mirror)
  case "${PKG_SOURCE}" in
    local|mixed|mixed-mirror)
      if [ -d "${LOCAL_PKG_REPO}" ]; then
        echo "[ OK ] local pkg repo exists: ${LOCAL_PKG_REPO}"
      else
        echo "[FAIL] local pkg repo directory missing: ${LOCAL_PKG_REPO}" >&2
        echo "       -> check LOCAL_PKG_REPO path, or set PKG_SOURCE=remote" >&2
        _errors=$((_errors + 1))
      fi
      ;;
  esac

  # Proxychains config (only when proxy enabled)
  if [ "${USE_PROXY}" = "yes" ]; then
    if [ -f "${PROXYCHAINS_CONF_HOST}" ]; then
      echo "[ OK ] proxychains config exists: ${PROXYCHAINS_CONF_HOST}"
    else
      echo "[FAIL] proxychains config missing: ${PROXYCHAINS_CONF_HOST}" >&2
      echo "       -> set USE_PROXY=no if you don't need a network proxy" >&2
      _errors=$((_errors + 1))
    fi
  fi

  # Pkglist file
  if [ -f "${PKGLIST_FILE}" ]; then
    echo "[ OK ] pkglist file exists: ${PKGLIST_FILE}"
  else
    echo "[FAIL] pkglist file missing: ${PKGLIST_FILE}" >&2
    _errors=$((_errors + 1))
  fi

  echo ""
  if [ "${_errors}" -eq 0 ]; then
    echo "All preflight checks passed."
    preflight_ok=1
  else
    echo "${_errors} check(s) failed." >&2
    preflight_ok=0
  fi
}

# --- Bastillefile generation ---

install_bastillefile() {
  _use_local=0
  case "${PKG_SOURCE}" in
    local|mixed|mixed-mirror) _use_local=1 ;;
  esac
  _use_proxy=0
  if [ "${USE_PROXY}" = "yes" ]; then
    _use_proxy=1
  fi
  _use_context_live=0
  if [ "${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}" = "yes" ]; then
    _use_context_live=1
  fi

  awk \
    -v use_local="${_use_local}" \
    -v use_proxy="${_use_proxy}" \
    -v use_context_live="${_use_context_live}" \
  '
    /^# @if-local-pkg$/    { in_local = 1; next }
    /^# @endif-local-pkg$/ { in_local = 0; next }
    /^# @if-context-live$/    { in_context_live = 1; next }
    /^# @endif-context-live$/ { in_context_live = 0; next }
    /^# @if-proxy$/        { in_proxy = 1; next }
    /^# @endif-proxy$/     { in_proxy = 0; next }
    in_local && !use_local { next }
    in_context_live && !use_context_live { next }
    in_proxy && !use_proxy { next }
    { print }
  ' "${CONFIG_ROOT}/Bastillefile" > "${TEMPLATE_ROOT}/Bastillefile"
}

# --- Helper functions ---

context_snapshot_copy_entry() {
  _snapshot_root="$1"
  _relative_path="$2"
  _src="${CONFIG_ROOT}/${_relative_path}"

  [ -e "${_src}" ] || return 0

  _dst="${_snapshot_root}/${_relative_path}"
  install -d "$(dirname "${_dst}")"
  if [ -d "${_src}" ]; then
    cp -R "${_src}" "${_dst}"
  else
    cp "${_src}" "${_dst}"
  fi
}

build_context_snapshot() {
  _snapshot_root="${TEMPLATE_ROOT}${OPENCLAW_CONTEXT_SNAPSHOT_DIR}"
  rm -rf "${_snapshot_root}"

  if [ "${OPENCLAW_CONTEXT_SNAPSHOT_ENABLE}" != "yes" ]; then
    return 0
  fi

  install -d "${_snapshot_root}"

  for _entry in \
    JAIL_ASSISTANT_ENV.md \
    Bastillefile \
    pkglist
  do
    context_snapshot_copy_entry "${_snapshot_root}" "${_entry}"
  done
}

force_unmount_jail_mounts() {
  mount_root="${JAIL_DIR}/root"

  bastille umount "${JAIL_NAME}" all >/dev/null 2>&1 || true

  mount -p \
    | awk -v root="${mount_root}" '$2 ~ ("^" root "(/|$)") { print length($2), $2 }' \
    | sort -rn \
    | awk '{ $1=""; sub(/^ /, ""); print }' \
    | while IFS= read -r mountpoint; do
      [ -n "${mountpoint}" ] || continue
      umount -f "${mountpoint}" >/dev/null 2>&1 || true
    done
}

vnet_iface_names() {
  printf '%s\n' "e0a_${JAIL_NAME}" "e0b_${JAIL_NAME}"
}

vnet_ifaces_exist() {
  for ifn in $(vnet_iface_names); do
    if ifconfig "${ifn}" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

cleanup_vnet_ifaces() {
  for ifn in $(vnet_iface_names); do
    if ifconfig "${ifn}" >/dev/null 2>&1; then
      ifconfig "${ifn}" destroy >/dev/null 2>&1 || true
    fi
  done
}

jail_registered() {
  bastille list jails 2>/dev/null | awk -v jail="${JAIL_NAME}" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == jail) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

jail_running() {
  jls -j "${JAIL_NAME}" jid >/dev/null 2>&1
}

jail_exists() {
  jail_registered || jail_running || [ -d "${JAIL_DIR}" ]
}

stop_jail() {
  if ! jail_exists; then
    echo "jail ${JAIL_NAME} does not exist; nothing to stop"
    return 0
  fi

  if ! jail_running; then
    echo "jail ${JAIL_NAME} is already stopped"
    return 0
  fi

  if jail_running; then
    if ! bastille stop "${JAIL_NAME}"; then
      echo "warning: failed to stop jail cleanly; trying bastille stop -a" >&2
      bastille stop -a "${JAIL_NAME}" >/dev/null 2>&1 || true
    fi
  fi

  # Ghost jail: bastille metadata gone but jail still registered in kernel.
  # Fall back to jail(8) to remove it directly.
  if jail_running; then
    echo "warning: jail still in kernel after bastille stop; using jail -r" >&2
    jail -r "${JAIL_NAME}" >/dev/null 2>&1 || true
  fi

  if jail_running; then
    echo "error: failed to stop jail: ${JAIL_NAME}" >&2
    return 1
  fi

  return 0
}

destroy_jail() {
  if ! stop_jail; then
    echo "warning: proceeding with destroy after stop failure" >&2
  fi

  force_unmount_jail_mounts

  if ! bastille destroy -af "${JAIL_NAME}"; then
    echo "warning: first destroy attempt failed; retrying after forced mount cleanup" >&2
    force_unmount_jail_mounts
    if jail_exists; then
      bastille destroy -af "${JAIL_NAME}" >/dev/null 2>&1 || true
    fi
  fi
}

# --- Action dispatch ---

if [ "${MODE}" = "stop" ]; then
  if ! command -v bastille >/dev/null 2>&1; then
    echo "bastille is not installed" >&2
    exit 1
  fi
  printf '\nStopping jail: %s\n\n' "${JAIL_NAME}"
  if ! stop_jail; then
    exit 1
  fi
  printf '\nJail "%s" stopped.\n\n' "${JAIL_NAME}"
  exit 0
fi

if [ "${MODE}" = "destroy" ]; then
  if ! command -v bastille >/dev/null 2>&1; then
    echo "bastille is not installed" >&2
    exit 1
  fi
  printf '\nDestroying jail: %s\n\n' "${JAIL_NAME}"
  if ! jail_exists; then
    echo "jail ${JAIL_NAME} does not exist; nothing to destroy"
    cleanup_vnet_ifaces
    exit 0
  fi
  destroy_jail
  cleanup_vnet_ifaces
  if jail_exists; then
    echo "error: failed to fully remove jail: ${JAIL_NAME}" >&2
    echo "hint: check 'bastille list jails', 'jls -j ${JAIL_NAME}', and stale path '${JAIL_DIR}'" >&2
    exit 1
  fi
  printf '\nJail "%s" destroyed.\n\n' "${JAIL_NAME}"
  exit 0
fi

# --- Run preflight ---

if [ "${SKIP_PREFLIGHT}" -eq 1 ]; then
  echo "Skipping preflight checks (--no-preflight)."
  preflight_ok=1
else
  echo "Running preflight checks..."
  echo ""
  preflight
fi

if [ "${MODE}" = "preflight" ]; then
  exit $((1 - preflight_ok))
fi

if [ "${preflight_ok}" -ne 1 ]; then
  echo "" >&2
  echo "Preflight failed. Fix the issues above before deploying." >&2
  echo "Run with --preflight for checks only." >&2
  exit 1
fi

echo ""

# --- Validate pkglist ---

if [ ! -f "${PKGLIST_FILE}" ]; then
  echo "missing pkglist file: ${PKGLIST_FILE}" >&2
  exit 1
fi

tmp_origins=$(mktemp -t openclaw-pkglist.XXXXXX)
trap 'rm -f "${tmp_origins}"' EXIT INT TERM

awk '
  BEGIN { ok = 1 }
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 1 { ok = 0; printf "invalid pkglist line: %s\n", $0 > "/dev/stderr"; next }
  $1 !~ /^[[:alnum:]][[:alnum:]+_.-]*\/[[:alnum:]][[:alnum:]+_.-]*$/ {
    ok = 0
    printf "invalid pkg origin: %s\n", $1 > "/dev/stderr"
    next
  }
  { print $1 }
  END { if (!ok) exit 1 }
' "${PKGLIST_FILE}" > "${tmp_origins}"

if [ ! -s "${tmp_origins}" ]; then
  echo "pkglist is empty after filtering comments/blank lines: ${PKGLIST_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC2086
for origin in ${BOOTSTRAP_ORIGINS}; do
  if ! grep -Fx -- "${origin}" "${tmp_origins}" >/dev/null; then
    echo "bootstrap origin missing from pkglist: ${origin}" >&2
    exit 1
  fi
done

LOCAL_BUILD_ORIGINS=$(awk -v bootstrap=" ${BOOTSTRAP_ORIGINS} " '
  { if (index(bootstrap, " " $1 " ") == 0) print $1 }
' "${tmp_origins}" | paste -sd' ' -)

if [ -z "${LOCAL_BUILD_ORIGINS}" ]; then
  echo "no build/runtime origins resolved from pkglist: ${PKGLIST_FILE}" >&2
  exit 1
fi

# --- Install template ---

install -d "${TEMPLATE_ROOT}"
install_bastillefile
rm -rf "${TEMPLATE_ROOT:?}/usr"
cp -R "${CONFIG_ROOT}/usr" "${TEMPLATE_ROOT}/usr"
build_context_snapshot
printf 'template installed at %s\n' "${TEMPLATE_ROOT}"

# --- Ensure host directories ---

install -d -m 0755 "${HOST_CONFIG_DIR}" "${HOST_WORKSPACE_DIR}" "${HOST_DATA_DIR}"
install -d -m 0700 "${HOST_STATE_DIR}"

# --- Destroy existing jail ---

if jail_exists; then
  printf '\nRemoving existing jail: %s\n\n' "${JAIL_NAME}"
  destroy_jail

  if jail_exists; then
    echo "error: failed to fully remove existing jail: ${JAIL_NAME}" >&2
    echo "hint: check 'bastille list jails', 'jls -j ${JAIL_NAME}', and stale path '${JAIL_DIR}'" >&2
    exit 1
  fi
fi

cleanup_vnet_ifaces
if vnet_ifaces_exist; then
  echo "error: stale vnet interfaces still exist for jail: ${JAIL_NAME}" >&2
  echo "hint: destroy them manually: ifconfig e0a_${JAIL_NAME} destroy; ifconfig e0b_${JAIL_NAME} destroy" >&2
  exit 1
fi

# --- Create jail ---

printf '\nCreating fresh jail: %s\n\n' "${JAIL_NAME}"
if ! bastille create -B "${JAIL_NAME}" "${RELEASE}" "${JAIL_IP}" "${BRIDGE_IF}"; then
  echo "warning: bastille create failed; cleaning stale vnet interfaces" >&2
  cleanup_vnet_ifaces
  exit 1
fi

# --- Apply template with conditional args ---
# Build the bastille template call directly with proper quoting.
# Space-separated values (origins lists) must be quoted as single --arg values,
# which is not possible with a flat tpl_args string due to word-splitting.

apply_template() {
  _cmd="bastille template ${JAIL_NAME} ${TEMPLATE_NAME}"
  _cmd="${_cmd} --arg PKG_SOURCE=${PKG_SOURCE}"
  _cmd="${_cmd} --arg USE_PROXY=${USE_PROXY}"

  case "${PKG_SOURCE}" in
    local|mixed|mixed-mirror)
      _cmd="${_cmd} --arg LOCAL_PKG_REPO=${LOCAL_PKG_REPO}"
      ;;
  esac

  case "${PKG_SOURCE}" in
    mirror|mixed-mirror)
      _cmd="${_cmd} --arg PKG_MIRROR_URL=${SELECTED_PKG_MIRROR_URL}"
      ;;
  esac

  if [ "${USE_PROXY}" = "yes" ]; then
    _cmd="${_cmd} --arg PROXYCHAINS_CONF_HOST=${PROXYCHAINS_CONF_HOST}"
  fi

  _cmd="${_cmd} --arg OPENCLAW_NPM_SPEC=${OPENCLAW_NPM_SPEC}"
  _cmd="${_cmd} --arg OPENCLAW_CONFIG_HOST=${HOST_CONFIG_DIR}"
  _cmd="${_cmd} --arg OPENCLAW_STATE_HOST=${HOST_STATE_DIR}"
  _cmd="${_cmd} --arg OPENCLAW_WORKSPACE_HOST=${HOST_WORKSPACE_DIR}"
  _cmd="${_cmd} --arg OPENCLAW_DATA_HOST=${HOST_DATA_DIR}"
  _cmd="${_cmd} --arg OPENCLAW_CONTEXT_SNAPSHOT_DIR=${OPENCLAW_CONTEXT_SNAPSHOT_DIR}"
  _cmd="${_cmd} --arg OPENCLAW_CONTEXT_REPO_DIR=${OPENCLAW_CONTEXT_REPO_DIR}"
  _cmd="${_cmd} --arg OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE=${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}"
  if [ "${OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE}" = "yes" ]; then
    _cmd="${_cmd} --arg OPENCLAW_CONTEXT_REPO_HOST=${OPENCLAW_CONTEXT_REPO_HOST}"
  fi
  _cmd="${_cmd} --arg PYTHON_BIN=${PYTHON_BIN}"

  # These args contain spaces (origin lists). Must be passed as individually quoted args.
  # shellcheck disable=SC2086
  ${_cmd} \
    --arg "LOCAL_BOOTSTRAP_ORIGINS=${BOOTSTRAP_ORIGINS}" \
    --arg "LOCAL_BUILD_ORIGINS=${LOCAL_BUILD_ORIGINS}"
}

if ! apply_template; then
  echo "warning: bastille template failed; cleaning up incomplete jail" >&2
  destroy_jail
  cleanup_vnet_ifaces
  exit 1
fi

# --- Deployment summary ---

printf '\nJail "%s" deployed successfully.\n\n' "${JAIL_NAME}"
echo "Next steps:"
echo "  bastille cmd ${JAIL_NAME} service openclaw_gateway init"
echo "  bastille cmd ${JAIL_NAME} service openclaw_gateway start"
echo ""

#!/bin/sh
set -eu

prog=$(basename "$0")

usage() {
  cat <<USAGE
Usage:
  ${prog} create [--pool <name>] [--dry-run]
  ${prog} destroy --yes [--pool <name>] [--dry-run]
  ${prog} verify [--pool <name>]

Description:
  Manage single-instance OpenClaw ZFS datasets.

  Reads ZPOOL_NAME and HOST_*_DIR from openclaw.conf (via lib/config.sh)
  when available. Defaults to zroot with standard mountpoints.

Options:
  --pool <name>  Override ZFS pool name (default: from config or zroot)
  --dry-run      Print commands without executing
  --yes          Confirm destructive destroy operation
USAGE
}

die() {
  echo "${prog}: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run_cmd() {
  if [ "${DRY_RUN}" = "YES" ]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

dataset_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

verify_dataset_property() {
  dataset="$1"
  property="$2"
  expected="$3"
  actual=$(zfs get -H -o value "${property}" "${dataset}" 2>/dev/null || true)
  if [ "${actual}" != "${expected}" ]; then
    die "dataset ${dataset} has ${property}=${actual}, expected ${expected}"
  fi
}

verify_created() {
  dataset_list="
${BASE_DATASET}|canmount|off
${BASE_DATASET}|mountpoint|none
${CONFIG_DATASET}|mountpoint|${HOST_CONFIG_DIR}
${STATE_DATASET}|mountpoint|${HOST_STATE_DIR}
${WORKSPACE_DATASET}|mountpoint|${HOST_WORKSPACE_DIR}
${DATA_DATASET}|mountpoint|${HOST_DATA_DIR}
"

  echo "Verifying created datasets under ${BASE_DATASET}..."
  echo "${dataset_list}" | while IFS='|' read -r dataset property expected; do
    [ -n "${dataset}" ] || continue
    if ! dataset_exists "${dataset}"; then
      die "expected dataset does not exist: ${dataset}"
    fi
    verify_dataset_property "${dataset}" "${property}" "${expected}"
  done
  echo "All required datasets exist with expected properties."
}

verify_destroyed() {
  dataset_list="
${BASE_DATASET}
${CONFIG_DATASET}
${STATE_DATASET}
${WORKSPACE_DATASET}
${DATA_DATASET}
"

  echo "Verifying datasets are destroyed under ${BASE_DATASET}..."
  echo "${dataset_list}" | while IFS= read -r dataset; do
    [ -n "${dataset}" ] || continue
    if dataset_exists "${dataset}"; then
      die "dataset still exists after destroy: ${dataset}"
    fi
  done
  echo "All target datasets are absent."
}

ensure_child_dataset() {
  dataset="$1"
  mountpoint="$2"

  if dataset_exists "${dataset}"; then
    run_cmd zfs set mountpoint="${mountpoint}" "${dataset}"
    run_cmd zfs set canmount=on "${dataset}"
  else
    run_cmd zfs create -o mountpoint="${mountpoint}" "${dataset}"
  fi
}

# --- Load config ---

CONFIG_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "${CONFIG_ROOT}/lib/config.sh" ]; then
  # shellcheck disable=SC1091
  . "${CONFIG_ROOT}/lib/config.sh"
fi

# --- Parse arguments ---

ACTION="${1:-}"
if [ -z "${ACTION}" ]; then
  usage >&2
  exit 1
fi
if [ "${ACTION}" = "--help" ] || [ "${ACTION}" = "-h" ]; then
  usage
  exit 0
fi
shift

POOL_OVERRIDE=""
CONFIRM_DESTROY="NO"
DRY_RUN="NO"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pool)
      [ "$#" -ge 2 ] || die "--pool requires an argument"
      POOL_OVERRIDE="$2"
      shift
      ;;
    --yes)
      CONFIRM_DESTROY="YES"
      ;;
    --dry-run)
      DRY_RUN="YES"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
  shift
done

[ "$#" -eq 0 ] || die "unexpected extra arguments: $*"

case "${ACTION}" in
  create|destroy|verify)
    ;;
  *)
    usage >&2
    die "unknown action: ${ACTION}"
    ;;
esac

# CLI --pool overrides config/default.
if [ -n "${POOL_OVERRIDE}" ]; then
  ZPOOL_NAME="${POOL_OVERRIDE}"
fi

require_cmd zpool
require_cmd zfs

if ! zpool list -H -o name "${ZPOOL_NAME}" >/dev/null 2>&1; then
  die "zpool not found: ${ZPOOL_NAME}"
fi

BASE_DATASET="${ZPOOL_NAME}/openclaw"
CONFIG_DATASET="${BASE_DATASET}/config"
STATE_DATASET="${BASE_DATASET}/state"
WORKSPACE_DATASET="${BASE_DATASET}/workspace"
DATA_DATASET="${BASE_DATASET}/data"

case "${ACTION}" in
  create)
    if dataset_exists "${BASE_DATASET}"; then
      run_cmd zfs set canmount=off "${BASE_DATASET}"
      run_cmd zfs set mountpoint=none "${BASE_DATASET}"
    else
      run_cmd zfs create -o canmount=off -o mountpoint=none "${BASE_DATASET}"
    fi

    ensure_child_dataset "${CONFIG_DATASET}" "${HOST_CONFIG_DIR}"
    ensure_child_dataset "${STATE_DATASET}" "${HOST_STATE_DIR}"
    ensure_child_dataset "${WORKSPACE_DATASET}" "${HOST_WORKSPACE_DIR}"
    ensure_child_dataset "${DATA_DATASET}" "${HOST_DATA_DIR}"

    if [ "${DRY_RUN}" = "YES" ]; then
      echo "Dry-run only. Skipped verification."
    else
      verify_created
    fi
    ;;
  destroy)
    [ "${CONFIRM_DESTROY}" = "YES" ] || die "destroy requires --yes"

    if dataset_exists "${BASE_DATASET}"; then
      run_cmd zfs destroy -r "${BASE_DATASET}"
    else
      echo "Base dataset does not exist: ${BASE_DATASET}"
    fi

    if [ "${DRY_RUN}" = "YES" ]; then
      echo "Dry-run only. Skipped verification."
    else
      verify_destroyed
    fi
    ;;
  verify)
    verify_created
    ;;
esac

#!/bin/sh
set -eu

runtime_home="${1:-}"
profile="${2:-}"
state_dir="${OPENCLAW_STATE_DIR:-/var/db/openclaw/state}"
legacy_paths_config='/usr/local/etc/openclaw/legacy-home-paths.conf'

legacy_home_dir_paths='.ssh .gnupg .kube .terraform.d .m2 .gradle .cargo .rustup .npm'
legacy_home_file_paths='.gitconfig .fetchrc .sh_history'

if [ -z "${runtime_home}" ] || [ -z "${profile}" ]; then
  echo "usage: $0 <runtime-home> <profile>" >&2
  exit 64
fi

if [ -r "${legacy_paths_config}" ]; then
  # shellcheck disable=SC1090
  if ! . "${legacy_paths_config}"; then
    echo "warning: failed to load legacy home config: ${legacy_paths_config}" >&2
  fi
fi

validate_rel_path() {
  _path="$1"
  case "${_path}" in
    ''|/*|*'..'*)
      return 1
      ;;
  esac
  return 0
}

ensure_dir_mode_700() {
  _dir="$1"
  install -d -m 0700 "${_dir}"
}

ensure_file_mode_600() {
  _file="$1"
  install -d -m 0700 "$(dirname "${_file}")"
  if [ ! -e "${_file}" ]; then
    : > "${_file}"
  fi
  chmod 0600 "${_file}" 2>/dev/null || true
}

ensure_symlink_to_target() {
  _source="$1"
  _target="$2"
  _kind="$3"

  install -d -m 0700 "$(dirname "${_source}")"
  install -d -m 0700 "$(dirname "${_target}")"

  if [ -L "${_source}" ]; then
    _current_target=$(readlink "${_source}" || true)
    if [ "${_current_target}" = "${_target}" ]; then
      return 0
    fi
    rm -f "${_source}"
  elif [ -e "${_source}" ]; then
    case "${_kind}" in
      dir)
        if [ -d "${_source}" ]; then
          find "${_source}" -mindepth 1 -maxdepth 1 -exec mv -n {} "${_target}/" \; 2>/dev/null || true
          rm -rf "${_source}" 2>/dev/null || true
        elif [ ! -e "${_target}" ]; then
          mv "${_source}" "${_target}" 2>/dev/null || true
        else
          rm -f "${_source}" 2>/dev/null || true
        fi
        ;;
      file)
        if [ ! -e "${_target}" ]; then
          mv "${_source}" "${_target}"
        else
          rm -f "${_source}" 2>/dev/null || true
        fi
        ;;
    esac
  fi

  ln -s "${_target}" "${_source}"
}

persist_home="${state_dir}/home/${profile}"
ensure_dir_mode_700 "${persist_home}"
ensure_dir_mode_700 "${runtime_home}"

set -f
for rel in ${legacy_home_dir_paths}; do
  if ! validate_rel_path "${rel}"; then
    echo "warning: ignore invalid legacy_home_dir_paths entry: ${rel}" >&2
    continue
  fi
  target="${persist_home}/${rel}"
  source="${runtime_home}/${rel}"
  ensure_dir_mode_700 "${target}"
  ensure_symlink_to_target "${source}" "${target}" dir
done

for rel in ${legacy_home_file_paths}; do
  if ! validate_rel_path "${rel}"; then
    echo "warning: ignore invalid legacy_home_file_paths entry: ${rel}" >&2
    continue
  fi
  target="${persist_home}/${rel}"
  source="${runtime_home}/${rel}"
  ensure_symlink_to_target "${source}" "${target}" file
  ensure_file_mode_600 "${target}"
done
set +f

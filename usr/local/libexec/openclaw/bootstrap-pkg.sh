#!/bin/sh
set -eu

# pkg(7) bootstrap phase — configure repos and install all declared packages.
repo_dir='/etc/pkg'
override_repo_dir='/usr/local/etc/pkg/repos'
local_repo_path='/mnt/poudriere'
bootstrap_origins='${LOCAL_BOOTSTRAP_ORIGINS}'
build_origins='${LOCAL_BUILD_ORIGINS}'
pkg_source='${PKG_SOURCE}'
pkg_mirror_url='${PKG_MIRROR_URL}'
use_proxy='${USE_PROXY}'

# Suppress all interactive prompts from pkg(7).  Exported once so that
# maybe_proxy (a shell function) passes it through to child processes.
export ASSUME_ALWAYS_YES=yes

# Route commands through proxychains when proxy is enabled AND the binary is
# available.  During early bootstrap proxychains-ng is not yet installed, so
# the check falls through to direct execution.  Once bootstrap origins
# (which include proxychains-ng) are installed, subsequent pkg commands are
# routed through the proxy.
maybe_proxy() {
  if [ "${use_proxy}" = "yes" ] && command -v proxychains >/dev/null 2>&1; then
    proxychains -q "$@"
  else
    "$@"
  fi
}

# Write mirror repo config to the override directory.
# pkg(7) variables ${ABI} and ${VERSION_MINOR} are expanded by pkg at runtime.
write_mirror_conf() {
  mkdir -p "${override_repo_dir}"
  cat > "${override_repo_dir}/Mirror.conf" <<CONF
mirror-ports: {
  url: "${pkg_mirror_url}/\${ABI}/quarterly",
  mirror_type: "none",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}

mirror-ports-kmods: {
  url: "${pkg_mirror_url}/\${ABI}/kmods_quarterly_\${VERSION_MINOR}",
  mirror_type: "none",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}

FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }
CONF
}

# Disable FreeBSD 15 default remote repos via override directory
# (recommended practice; avoids modifying /etc/pkg/FreeBSD.conf).
disable_remote_repos() {
  mkdir -p "${override_repo_dir}"
  cat > "${override_repo_dir}/DisableRemote.conf" <<'CONF'
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }
CONF
}

# --- Configure pkg repositories ---

mkdir -p "${repo_dir}"

case "${pkg_source}" in
  local)
    disable_remote_repos
    cat > "${repo_dir}/OpenClawLocal.conf" <<CONF
OpenClawLocal: {
  url: "file://${local_repo_path}",
  enabled: yes,
  priority: 100
}
CONF
    echo "pkg repo configured: local only (file://${local_repo_path})"
    ;;
  remote)
    echo "pkg repo configured: FreeBSD remote (default)"
    ;;
  mixed)
    cat > "${repo_dir}/OpenClawLocal.conf" <<CONF
OpenClawLocal: {
  url: "file://${local_repo_path}",
  enabled: yes,
  priority: 100
}
CONF
    echo "pkg repo configured: mixed (local priority + FreeBSD remote)"
    ;;
  mirror)
    write_mirror_conf
    echo "pkg repo configured: mirror (${pkg_mirror_url})"
    ;;
  mixed-mirror)
    cat > "${repo_dir}/OpenClawLocal.conf" <<CONF
OpenClawLocal: {
  url: "file://${local_repo_path}",
  enabled: yes,
  priority: 100
}
CONF
    write_mirror_conf
    echo "pkg repo configured: mixed-mirror (local priority + mirror ${pkg_mirror_url})"
    ;;
  *)
    echo "unknown PKG_SOURCE value: ${pkg_source}" >&2
    exit 1
    ;;
esac

# --- Phase 1: Bootstrap pkg and install bootstrap origins ---
#
# For mixed+proxy, temporarily disable FreeBSD remote repos so that pkg
# update only touches the local repo.  This avoids network timeouts and
# lets us install bootstrap origins (including proxychains-ng) from local
# before any remote access is attempted.

two_phase=0
if [ "${pkg_source}" = "mixed" ] && [ "${use_proxy}" = "yes" ]; then
  two_phase=1
  disable_remote_repos
  echo "phase 1: remote repos temporarily disabled for bootstrap"
fi

pkg_static=''
local_pkgs_installed=0
for candidate in /usr/local/sbin/pkg-static /usr/sbin/pkg-static pkg-static; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    pkg_static=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    pkg_static="${candidate}"
    break
  fi
done

if [ -n "${pkg_static}" ]; then
  maybe_proxy "${pkg_static}" update -f
  # shellcheck disable=SC2086
  maybe_proxy "${pkg_static}" install -y ${bootstrap_origins}
  local_pkgs_installed=1
else
  # FreeBSD base jails may not include pkg-static; bootstrap pkg from local repo.
  pkg_bootstrap=''
  for candidate in /usr/sbin/pkg pkg; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      pkg_bootstrap=$(command -v "${candidate}")
      break
    elif [ -x "${candidate}" ]; then
      pkg_bootstrap="${candidate}"
      break
    fi
  done

  if [ -z "${pkg_bootstrap}" ]; then
    echo 'pkg-static and pkg bootstrap helper are both unavailable inside jail' >&2
    exit 1
  fi

  maybe_proxy "${pkg_bootstrap}" bootstrap -f
fi

pkg_cmd=''
for candidate in /usr/local/sbin/pkg /usr/sbin/pkg pkg; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    pkg_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    pkg_cmd="${candidate}"
    break
  fi
done

if [ -z "${pkg_cmd}" ]; then
  echo 'pkg command not found after bootstrap' >&2
  exit 1
fi

if [ "${local_pkgs_installed}" -eq 0 ]; then
  # shellcheck disable=SC2086
  maybe_proxy "${pkg_cmd}" install -y ${bootstrap_origins}
fi

# --- Phase 2: Full repo update and build origins ---
#
# For mixed+proxy, proxychains-ng is now installed.  Re-enable FreeBSD
# remote repos so build origins can fall back to remote if not in local.

if [ "${two_phase}" -eq 1 ]; then
  rm -f "${override_repo_dir}/DisableRemote.conf"
  echo "phase 2: remote repos re-enabled, proxychains available"
fi

maybe_proxy "${pkg_cmd}" update -f

if [ -n "${build_origins}" ]; then
  # shellcheck disable=SC2086
  maybe_proxy "${pkg_cmd}" install -y ${build_origins}
fi

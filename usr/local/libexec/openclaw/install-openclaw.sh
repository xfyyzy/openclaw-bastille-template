#!/bin/sh
set -eu

openclaw_npm_spec='${OPENCLAW_NPM_SPEC}'
install_root='${OPENCLAW_INSTALL_ROOT}'
db_dir='${OPENCLAW_DB_DIR}'
state_dir='${OPENCLAW_STATE_DIR}'
workspace_dir='${OPENCLAW_WORKSPACE}'
config_path='${OPENCLAW_ETC_DIR}/openclaw.json'
runtime_context_path='${OPENCLAW_ETC_DIR}/runtime-context.env'
proxy_routing_path='${OPENCLAW_ETC_DIR}/proxy-routing.conf'
proxy_routing_default_path='/usr/local/share/openclaw/defaults/proxy-routing.conf'
legacy_home_paths_path='${OPENCLAW_ETC_DIR}/legacy-home-paths.conf'
legacy_home_paths_default_path='/usr/local/share/openclaw/defaults/legacy-home-paths.conf'
prepare_stateful_home='/usr/local/libexec/openclaw/prepare-stateful-home.sh'
searxng_settings_path='${OPENCLAW_ETC_DIR}/searxng.yml'
use_proxy='${USE_PROXY}'
python_bin='${PYTHON_BIN}'
proxy_enabled='no'

if [ "${use_proxy}" = "yes" ]; then
  proxy_enabled='yes'
fi

# Packages whose postinstall/build scripts are allowed to run.
# All other packages have their scripts suppressed via --ignore-scripts.
rebuild_pkgs="@whiskeysockets/baileys koffi protobufjs sharp"

# Route commands through proxychains when proxy is enabled.
maybe_proxy() {
  if [ "${use_proxy}" = "yes" ]; then
    proxychains -q "$@"
  else
    "$@"
  fi
}

mkdir -p "${state_dir}" "${workspace_dir}" "$(dirname "${config_path}")"
rm -rf "${install_root}"
mkdir -p "${install_root}"
install -d -m 0700 "${state_dir}/xdg/config" "${state_dir}/xdg/state" "${state_dir}/xdg/cache"

export CI=1

node_cmd=''
for candidate in /usr/local/bin/node node; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    node_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    node_cmd="${candidate}"
    break
  fi
done

if [ -z "${node_cmd}" ]; then
  echo "node command not found inside jail (expected from node package)" >&2
  exit 1
fi

npm_cmd=''
for candidate in /usr/local/bin/npm npm; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    npm_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    npm_cmd="${candidate}"
    break
  fi
done

if [ -z "${npm_cmd}" ]; then
  echo "npm command not found inside jail (expected from npm-node package)" >&2
  exit 1
fi

python_cmd=''
for candidate in "/usr/local/bin/${python_bin}" /usr/local/bin/python3 "${python_bin}" python3 python; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    python_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    python_cmd="${candidate}"
    break
  fi
done

if [ -z "${python_cmd}" ]; then
  echo "python command not found inside jail (expected ${python_bin})" >&2
  exit 1
fi

# Keep a stable python3 entrypoint for automation tools.
if [ ! -x /usr/local/bin/python3 ] && [ -x "/usr/local/bin/${python_bin}" ]; then
  ln -sf "/usr/local/bin/${python_bin}" /usr/local/bin/python3
fi

export PYTHON="${python_cmd}"

cat > "${install_root}/package.json" <<'JSON'
{
  "name": "openclaw-runtime",
  "private": true,
  "dependencies": {
    "node-addon-api": "^8.6.0",
    "node-gyp": "^11.5.0"
  }
}
JSON

# Install openclaw with all build scripts suppressed, then selectively
# rebuild only the packages that need native compilation.
# This replaces pnpm's onlyBuiltDependencies with an equivalent two-step approach.
maybe_proxy "${npm_cmd}" install --prefix "${install_root}" --omit=dev --ignore-scripts "${openclaw_npm_spec}"

# shellcheck disable=SC2086
"${npm_cmd}" rebuild --prefix "${install_root}" ${rebuild_pkgs}

package_root="${install_root}/node_modules/openclaw"
if [ ! -f "${package_root}/openclaw.mjs" ]; then
  echo "openclaw entrypoint not found after npm install: ${package_root}/openclaw.mjs" >&2
  exit 1
fi

version="$("${node_cmd}" -e 'process.stdout.write(require(process.argv[1]).version)' "${package_root}/package.json")"
printf '%s\n' "${version}" > "${install_root}/.openclaw-version"

# Clean stale bundled-extension paths from plugins.load.paths.
# Bundled extensions (e.g. feishu, telegram) are auto-discovered from
# <install_root>/node_modules/openclaw/extensions/ and never need explicit
# path entries.  Stale entries accumulate when the package manager changes
# (pnpm -> npm) or openclaw is upgraded, causing "plugin path not found" errors.
if [ -s "${config_path}" ]; then
  "${node_cmd}" -e '
    const fs = require("fs");
    const p = process.argv[1];
    let raw, cfg;
    try { raw = fs.readFileSync(p, "utf8"); } catch { process.exit(0); }
    try { cfg = JSON.parse(raw); } catch { process.exit(0); }
    const paths = cfg?.plugins?.load?.paths;
    if (!Array.isArray(paths) || paths.length === 0) process.exit(0);
    const cleaned = paths.filter(e =>
      !e.includes("/node_modules/openclaw/extensions/") &&
      !e.includes("/node_modules/.pnpm/")
    );
    if (cleaned.length === paths.length) process.exit(0);
    if (cleaned.length > 0) {
      cfg.plugins.load.paths = cleaned;
    } else {
      delete cfg.plugins.load.paths;
      if (Object.keys(cfg.plugins.load).length === 0) delete cfg.plugins.load;
      if (Object.keys(cfg.plugins).length === 0) delete cfg.plugins;
    }
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
    const removed = paths.length - cleaned.length;
    console.log("Cleaned " + removed + " stale bundled-extension path(s) from plugins.load.paths");
  ' "${config_path}" || echo "warning: failed to clean stale plugin paths (non-fatal)" >&2
fi

# Reinstall plugins from persistent manifest (survives jail rebuilds).
# The manifest is maintained by the openclaw wrapper's plugins install/uninstall hooks.
plugin_manifest="${state_dir}/plugins.txt"
if [ -f "${plugin_manifest}" ] && [ -s "${plugin_manifest}" ]; then
  echo "Reinstalling plugins from manifest: ${plugin_manifest}"
  while IFS= read -r _plugin_spec || [ -n "${_plugin_spec}" ]; do
    case "${_plugin_spec}" in '#'*|'') continue ;; esac
    echo "  installing plugin: ${_plugin_spec}"
    maybe_proxy "${npm_cmd}" install --prefix "${install_root}" --omit=dev "${_plugin_spec}" || {
      echo "  warning: failed to install plugin: ${_plugin_spec}" >&2
    }
  done < "${plugin_manifest}"
fi

if [ ! -s "${config_path}" ]; then
  mkdir -p "$(dirname "${config_path}")"
  cat > "${config_path}" <<JSON
{
  "agents": {
    "defaults": {
      "workspace": "${workspace_dir}"
    }
  }
}
JSON
fi

cat > "${runtime_context_path}" <<EOF_CTX
# Generated during deploy/install. Read by in-jail assistant contract.
OPENCLAW_PROXY_ENABLED=${proxy_enabled}
EOF_CTX
chmod 0644 "${runtime_context_path}"

if [ ! -s "${proxy_routing_path}" ]; then
  if [ ! -r "${proxy_routing_default_path}" ]; then
    echo "proxy routing template missing: ${proxy_routing_default_path}" >&2
    exit 1
  fi
  install -m 0644 "${proxy_routing_default_path}" "${proxy_routing_path}"
  chmod 0644 "${proxy_routing_path}"
fi

if [ ! -s "${legacy_home_paths_path}" ]; then
  if [ ! -r "${legacy_home_paths_default_path}" ]; then
    echo "legacy home template missing: ${legacy_home_paths_default_path}" >&2
    exit 1
  fi
  install -m 0644 "${legacy_home_paths_default_path}" "${legacy_home_paths_path}"
  chmod 0644 "${legacy_home_paths_path}"
fi

if [ ! -x "${prepare_stateful_home}" ]; then
  echo "stateful home helper not found: ${prepare_stateful_home}" >&2
  exit 1
fi

OPENCLAW_STATE_DIR="${state_dir}" "${prepare_stateful_home}" /root root
OPENCLAW_STATE_DIR="${state_dir}" "${prepare_stateful_home}" "${db_dir}" openclaw

if [ ! -s "${searxng_settings_path}" ]; then
  searxng_secret="$("${python_cmd}" -c 'import secrets; print(secrets.token_hex(32))')"
  cat > "${searxng_settings_path}" <<YAML
use_default_settings: true
search:
  formats:
    - html
    - json
engines:
  - name: wikidata
    disabled: true
  - name: ahmia
    disabled: true
  - name: torch
    disabled: true
  - name: yacy images
    disabled: true
server:
  bind_address: "127.0.0.1"
  port: 8888
  secret_key: "${searxng_secret}"
  limiter: false
  public_instance: false
  image_proxy: false
YAML
  chmod 0644 "${searxng_settings_path}"
fi

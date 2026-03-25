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
enable_local_embeddings='${OPENCLAW_ENABLE_LOCAL_EMBEDDINGS}'
proxy_enabled='no'
sqlite_vec_extension_path=''

if [ "${use_proxy}" = "yes" ]; then
  proxy_enabled='yes'
fi

case "${enable_local_embeddings}" in
  yes|no) ;;
  *)
    echo "OPENCLAW_ENABLE_LOCAL_EMBEDDINGS must be yes or no: ${enable_local_embeddings}" >&2
    exit 1
    ;;
esac

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
install -d -m 0700 "${state_dir}/cargo" "${state_dir}/rustup" "${state_dir}/sccache"

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

openclaw_cmd=''
for candidate in /usr/local/bin/openclaw openclaw; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    openclaw_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    openclaw_cmd="${candidate}"
    break
  fi
done

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

curl_cmd=''
for candidate in /usr/local/bin/curl /usr/bin/curl curl; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    curl_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    curl_cmd="${candidate}"
    break
  fi
done

if [ -z "${curl_cmd}" ]; then
  echo "curl command not found inside jail (required for sqlite-vec source bootstrap)" >&2
  exit 1
fi

cc_cmd=''
for candidate in /usr/bin/cc /usr/bin/clang cc clang /usr/local/bin/gcc gcc; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    cc_cmd=$(command -v "${candidate}")
    break
  elif [ -x "${candidate}" ]; then
    cc_cmd="${candidate}"
    break
  fi
done

if [ -z "${cc_cmd}" ]; then
  echo "C compiler command not found inside jail (required for sqlite-vec source bootstrap)" >&2
  exit 1
fi

# Keep a stable python3 entrypoint for automation tools.
if [ ! -x /usr/local/bin/python3 ] && [ -x "/usr/local/bin/${python_bin}" ]; then
  ln -sf "/usr/local/bin/${python_bin}" /usr/local/bin/python3
fi

# FreeBSD ships rustup as rustup-init; provide a stable rustup entrypoint.
if [ -x /usr/local/bin/rustup-init ] && [ ! -x /usr/local/bin/rustup ]; then
  ln -sf /usr/local/bin/rustup-init /usr/local/bin/rustup
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

package_root="${install_root}/node_modules/openclaw"
if [ ! -f "${package_root}/openclaw.mjs" ]; then
  echo "openclaw entrypoint not found after npm install: ${package_root}/openclaw.mjs" >&2
  exit 1
fi

if [ "${enable_local_embeddings}" = "yes" ]; then
  node_llama_spec="$("${node_cmd}" -e '
    const pkg = require(process.argv[1]);
    const spec = pkg?.peerDependencies?.["node-llama-cpp"];
    process.stdout.write(spec ? `node-llama-cpp@${spec}` : "node-llama-cpp");
  ' "${package_root}/package.json")"
  echo "installing optional local embedding dependency: ${node_llama_spec}"
  maybe_proxy "${npm_cmd}" install --prefix "${install_root}" --omit=dev "${node_llama_spec}"
  rebuild_pkgs="${rebuild_pkgs} node-llama-cpp"
else
  echo "skipping optional local embedding dependency bootstrap (OPENCLAW_ENABLE_LOCAL_EMBEDDINGS=${enable_local_embeddings})"
fi

if [ "${enable_local_embeddings}" = "yes" ]; then
  sqlite_vec_pkg_json="${install_root}/node_modules/sqlite-vec/package.json"
  if [ ! -f "${sqlite_vec_pkg_json}" ]; then
    echo "error: sqlite-vec dependency metadata missing: ${sqlite_vec_pkg_json}" >&2
    echo "error: sqlite-vec source build failed; aborting deploy." >&2
    exit 1
  fi

  sqlite_vec_version="$("${node_cmd}" -e '
    const pkg = require(process.argv[1]);
    process.stdout.write(String(pkg?.version ?? ""));
  ' "${sqlite_vec_pkg_json}")"
  if [ -z "${sqlite_vec_version}" ]; then
    echo "error: unable to resolve sqlite-vec dependency version from ${sqlite_vec_pkg_json}" >&2
    echo "error: sqlite-vec source build failed; aborting deploy." >&2
    exit 1
  fi

  sqlite_vec_version_major=$(printf '%s' "${sqlite_vec_version}" | cut -d. -f1)
  sqlite_vec_version_minor=$(printf '%s' "${sqlite_vec_version}" | cut -d. -f2)
  sqlite_vec_version_patch=$(printf '%s' "${sqlite_vec_version}" | cut -d. -f3 | cut -d- -f1)
  case "${sqlite_vec_version_major}${sqlite_vec_version_minor}${sqlite_vec_version_patch}" in
    ''|*[!0-9]*)
      echo "error: sqlite-vec version is not semver-like: ${sqlite_vec_version}" >&2
      echo "error: sqlite-vec source build failed; aborting deploy." >&2
      exit 1
      ;;
  esac

  sqlite_vec_extension_dir="${state_dir}/native/sqlite-vec/${sqlite_vec_version}"
  sqlite_vec_extension_path="${sqlite_vec_extension_dir}/vec0.so"
  sqlite_vec_tarball_url="https://github.com/asg017/sqlite-vec/archive/refs/tags/v${sqlite_vec_version}.tar.gz"
  sqlite_vec_build_tmp="${state_dir}/build/sqlite-vec/tmp"

  if [ ! -s "${sqlite_vec_extension_path}" ]; then
    mkdir -p "${sqlite_vec_extension_dir}" "${sqlite_vec_build_tmp}"
    sqlite_vec_stage=$(mktemp -d "${sqlite_vec_build_tmp}/build.XXXXXX")
    sqlite_vec_tarball="${sqlite_vec_stage}/sqlite-vec.tar.gz"
    sqlite_vec_src_root="${sqlite_vec_stage}/src"
    sqlite_vec_src_dir="${sqlite_vec_src_root}/sqlite-vec-${sqlite_vec_version}"
    sqlite_vec_generated_header="${sqlite_vec_src_dir}/sqlite-vec.h"
    sqlite_vec_generated_header_tmp="${sqlite_vec_generated_header}.tmp"
    sqlite_vec_compiled_tmp="${sqlite_vec_extension_path}.tmp"
    sqlite_vec_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    echo "Building sqlite-vec loadable extension from source (version ${sqlite_vec_version})..."
    if ! maybe_proxy "${curl_cmd}" -fsSL "${sqlite_vec_tarball_url}" -o "${sqlite_vec_tarball}"; then
      echo "error: failed to download sqlite-vec source tarball: ${sqlite_vec_tarball_url}" >&2
      echo "error: sqlite-vec source build failed; aborting deploy." >&2
      exit 1
    fi

    mkdir -p "${sqlite_vec_src_root}"
    if ! tar -xzf "${sqlite_vec_tarball}" -C "${sqlite_vec_src_root}"; then
      echo "error: failed to extract sqlite-vec source tarball: ${sqlite_vec_tarball}" >&2
      echo "error: sqlite-vec source build failed; aborting deploy." >&2
      exit 1
    fi
    if [ ! -d "${sqlite_vec_src_dir}" ]; then
      echo "error: sqlite-vec source directory missing after extract: ${sqlite_vec_src_dir}" >&2
      echo "error: sqlite-vec source build failed; aborting deploy." >&2
      exit 1
    fi

    if ! sed \
      -e "s|\${VERSION}|${sqlite_vec_version}|g" \
      -e "s|\${DATE}|${sqlite_vec_date}|g" \
      -e "s|\${SOURCE}|openclaw-bastille-template|g" \
      -e "s|\${VERSION_MAJOR}|${sqlite_vec_version_major}|g" \
      -e "s|\${VERSION_MINOR}|${sqlite_vec_version_minor}|g" \
      -e "s|\${VERSION_PATCH}|${sqlite_vec_version_patch}|g" \
      "${sqlite_vec_src_dir}/sqlite-vec.h.tmpl" > "${sqlite_vec_generated_header_tmp}"; then
      echo "error: failed to render sqlite-vec.h from template" >&2
      echo "error: sqlite-vec source build failed; aborting deploy." >&2
      exit 1
    fi
    mv "${sqlite_vec_generated_header_tmp}" "${sqlite_vec_generated_header}"

    if ! "${cc_cmd}" -fPIC -shared -Wall -Wextra -O3 \
      -include sys/types.h \
      -I/usr/local/include \
      -I"${sqlite_vec_src_dir}" \
      -I"${sqlite_vec_src_dir}/vendor" \
      "${sqlite_vec_src_dir}/sqlite-vec.c" \
      -lm \
      -o "${sqlite_vec_compiled_tmp}"; then
      echo "error: failed to compile sqlite-vec loadable extension with ${cc_cmd}" >&2
      echo "error: sqlite-vec source build failed; aborting deploy." >&2
      exit 1
    fi

    mv "${sqlite_vec_compiled_tmp}" "${sqlite_vec_extension_path}"
    chmod 0644 "${sqlite_vec_extension_path}"
    rm -rf "${sqlite_vec_stage}"
  else
    echo "Reusing cached sqlite-vec loadable extension: ${sqlite_vec_extension_path}"
  fi
fi

# shellcheck disable=SC2086
"${npm_cmd}" rebuild --prefix "${install_root}" ${rebuild_pkgs}

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

# Reinstall plugins from persistent manifest (survives jail rebuilds).
# The manifest is maintained by the openclaw wrapper's plugins install/uninstall hooks.
# Restore via OpenClaw CLI so plugin source/channel behavior follows upstream defaults.
plugin_manifest="${state_dir}/plugins.txt"
if [ -f "${plugin_manifest}" ] && [ -s "${plugin_manifest}" ]; then
  if [ -z "${openclaw_cmd}" ]; then
    echo "error: openclaw command not found; cannot restore plugins from manifest" >&2
    exit 1
  fi
  echo "Reinstalling plugins from manifest via openclaw CLI: ${plugin_manifest}"
  plugin_manifest_snapshot=$(mktemp -t openclaw-plugin-manifest.XXXXXX)
  cp "${plugin_manifest}" "${plugin_manifest_snapshot}"
  while IFS= read -r _plugin_spec || [ -n "${_plugin_spec}" ]; do
    case "${_plugin_spec}" in '#'*|'') continue ;; esac
    echo "  installing plugin: ${_plugin_spec}"
    if ! "${openclaw_cmd}" plugins install "${_plugin_spec}"; then
      rm -f "${plugin_manifest_snapshot}"
      echo "error: failed to install plugin from manifest via openclaw CLI: ${_plugin_spec}" >&2
      exit 1
    fi
  done < "${plugin_manifest_snapshot}"
  rm -f "${plugin_manifest_snapshot}"
fi

if [ "${enable_local_embeddings}" = "yes" ]; then
  if [ -z "${sqlite_vec_extension_path}" ] || [ ! -s "${sqlite_vec_extension_path}" ]; then
    echo "error: sqlite-vec extension path unresolved for local embeddings bootstrap" >&2
    exit 1
  fi
  if ! "${node_cmd}" -e '
    const fs = require("fs");
    const p = process.argv[1];
    const extensionPath = process.argv[2];
    let cfg;
    try {
      cfg = JSON.parse(fs.readFileSync(p, "utf8"));
    } catch (err) {
      console.error("invalid openclaw config JSON:", p);
      process.exit(1);
    }
    cfg.agents ??= {};
    cfg.agents.defaults ??= {};
    cfg.agents.defaults.memorySearch ??= {};
    cfg.agents.defaults.memorySearch.store ??= {};
    cfg.agents.defaults.memorySearch.store.vector ??= {};
    cfg.agents.defaults.memorySearch.store.vector.extensionPath = extensionPath;
    const requestedProvider = typeof cfg.agents.defaults.memorySearch.provider === "string"
      ? cfg.agents.defaults.memorySearch.provider.trim()
      : "";
    if (!requestedProvider || requestedProvider === "auto" || requestedProvider === "none") {
      cfg.agents.defaults.memorySearch.provider = "local";
    }
    if (cfg.agents.defaults.memorySearch.provider === "local") {
      cfg.agents.defaults.memorySearch.local ??= {};
      if (
        typeof cfg.agents.defaults.memorySearch.local.modelPath !== "string" ||
        !cfg.agents.defaults.memorySearch.local.modelPath.trim()
      ) {
        cfg.agents.defaults.memorySearch.local.modelPath = "hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf";
      }
      if (
        typeof cfg.agents.defaults.memorySearch.fallback !== "string" ||
        !cfg.agents.defaults.memorySearch.fallback.trim()
      ) {
        cfg.agents.defaults.memorySearch.fallback = "none";
      }
    }
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  ' "${config_path}" "${sqlite_vec_extension_path}"; then
    echo "error: failed to persist sqlite-vec extensionPath into config: ${config_path}" >&2
    exit 1
  fi
  echo "Configured sqlite-vec extensionPath for memory search: ${sqlite_vec_extension_path}"
  echo "Ensured local memory embedding defaults are pinned for FreeBSD bootstrap."
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

if [ "${enable_local_embeddings}" = "yes" ]; then
  if [ -n "${openclaw_cmd}" ]; then
    echo "Prewarming local memory embeddings via openclaw memory status --deep --index..."
    memory_prewarm_status_json=$(mktemp -t openclaw-memory-prewarm.XXXXXX)
    if ! maybe_proxy "${openclaw_cmd}" memory status --deep --index --json > "${memory_prewarm_status_json}"; then
      rm -f "${memory_prewarm_status_json}"
      echo "error: memory prewarm failed; aborting deploy." >&2
      exit 1
    fi
    # memory status --index may refresh manager state during reindex, so probe
    # once more without --index before enforcing strict readiness checks.
    if ! maybe_proxy "${openclaw_cmd}" memory status --deep --json > "${memory_prewarm_status_json}"; then
      rm -f "${memory_prewarm_status_json}"
      echo "error: memory prewarm failed; aborting deploy." >&2
      exit 1
    fi
    if ! "${node_cmd}" -e '
      const fs = require("fs");
      const p = process.argv[1];
      const raw = fs.readFileSync(p, "utf8");
      const normalized = raw.replace(/\r/g, "\n");
      const tryParse = (text) => {
        try {
          return JSON.parse(text);
        } catch {
          return null;
        }
      };
      let status = tryParse(normalized.trim());
      if (status === null) {
        // Some builds still emit spinner/progress chars to stdout with --json.
        const deansi = normalized.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "");
        status = tryParse(deansi.trim());
      }
      if (status === null) {
        for (let i = 0; i < normalized.length; i++) {
          const start = normalized[i];
          if (start !== "[" && start !== "{") {
            continue;
          }
          for (let j = normalized.length; j > i; j--) {
            const end = normalized[j - 1];
            if ((start === "[" && end !== "]") || (start === "{" && end !== "}")) {
              continue;
            }
            const candidate = normalized.slice(i, j).trim();
            if (!candidate) {
              continue;
            }
            status = tryParse(candidate);
            if (status !== null) {
              break;
            }
          }
          if (status !== null) {
            break;
          }
        }
      }
      if (status === null) {
        console.error("prewarm check: unable to parse memory status JSON: no valid JSON payload found in command output.");
        process.exit(1);
      }
      if (!Array.isArray(status) || status.length === 0) {
        console.error("prewarm check: memory status JSON did not include agent results.");
        process.exit(1);
      }
      const failures = [];
      for (const entry of status) {
        const agentId = typeof entry?.agentId === "string" && entry.agentId.trim() ? entry.agentId.trim() : "default";
        const provider = typeof entry?.status?.provider === "string" ? entry.status.provider.trim() : "";
        const requestedProvider = typeof entry?.status?.requestedProvider === "string" ? entry.status.requestedProvider.trim() : "";
        if (provider !== "local") {
          failures.push(`[${agentId}] provider is "${provider || "unknown"}" (requested: "${requestedProvider || "unknown"}"), expected "local".`);
        }
        if (entry?.embeddingProbe?.ok !== true) {
          const reason = typeof entry?.embeddingProbe?.error === "string" && entry.embeddingProbe.error.trim()
            ? entry.embeddingProbe.error.trim()
            : "unknown embedding probe failure";
          failures.push(`[${agentId}] embeddings unavailable: ${reason}`);
        }
        const vector = entry?.status?.vector;
        if (!vector || vector.enabled === false) {
          failures.push(`[${agentId}] sqlite-vec vector index is disabled.`);
        } else if (vector.available !== true) {
          const reason = typeof vector?.loadError === "string" && vector.loadError.trim()
            ? vector.loadError.trim()
            : "vector status is not ready";
          failures.push(`[${agentId}] sqlite-vec vector index unavailable: ${reason}`);
        }
      }
      if (failures.length > 0) {
        console.error("prewarm check: local memory embeddings semantic validation failed:");
        for (const line of failures) {
          console.error(`- ${line}`);
        }
        process.exit(1);
      }
    ' "${memory_prewarm_status_json}"; then
      rm -f "${memory_prewarm_status_json}"
      echo "error: strict local memory prewarm validation failed; aborting deploy." >&2
      exit 1
    fi
    rm -f "${memory_prewarm_status_json}"
  else
    echo "error: openclaw command not found; cannot prewarm memory embeddings." >&2
    exit 1
  fi
fi

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

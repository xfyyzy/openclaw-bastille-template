#!/bin/sh
set -eu

use_proxy='${USE_PROXY}'
settings_path='${OPENCLAW_ETC_DIR}/searxng.yml'
run_bin='/usr/local/bin/searxng-run'
bind_address='127.0.0.1'
listen_port='8888'

if [ ! -x "${run_bin}" ]; then
  echo "searxng entrypoint not found: ${run_bin}" >&2
  exit 1
fi

if [ ! -s "${settings_path}" ]; then
  echo "searxng settings not found: ${settings_path}" >&2
  exit 1
fi

# Keep the service jail-local even if the persisted yaml is manually edited.
export SEARXNG_SETTINGS_PATH="${settings_path}"
export SEARXNG_BIND_ADDRESS="${bind_address}"
export SEARXNG_PORT="${listen_port}"

if [ "${use_proxy}" = "yes" ]; then
  proxychains_bin=$(command -v proxychains 2>/dev/null || true)
  if [ -z "${proxychains_bin}" ]; then
    echo "proxy mode enabled but proxychains not found in jail" >&2
    exit 1
  fi
  exec "${proxychains_bin}" -q "${run_bin}" "$@"
fi

exec "${run_bin}" "$@"

#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALL_SCRIPT="${ROOT}/usr/local/libexec/openclaw/install-openclaw.sh"
README="${ROOT}/README.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if ! rg -n --fixed-strings "sqlite_vec_extension_path=''" "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing sqlite_vec_extension_path bootstrap variable in install script"
fi

if ! rg -n --fixed-strings 'sqlite_vec_tarball_url="https://github.com/asg017/sqlite-vec/archive/refs/tags/v${sqlite_vec_version}.tar.gz"' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing sqlite-vec tarball URL derivation from resolved version"
fi

if ! rg -n --fixed-strings 'Building sqlite-vec loadable extension from source (version ${sqlite_vec_version})...' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing sqlite-vec source build log line"
fi

if ! rg -n --fixed-strings 'error: sqlite-vec source build failed; aborting deploy.' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing fatal sqlite-vec source build failure path"
fi

if ! rg -n --fixed-strings 'Configured sqlite-vec extensionPath for memory search:' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing config extensionPath wiring log line"
fi

if ! rg -n --fixed-strings 'sqlite-vec loadable extension from source on FreeBSD' "${README}" >/dev/null 2>&1; then
  fail "missing README sqlite-vec source-build documentation"
fi

if ! rg -n --fixed-strings 'memorySearch.store.vector.extensionPath' "${README}" >/dev/null 2>&1; then
  fail "missing README extensionPath documentation for sqlite-vec"
fi

echo "PASS: sqlite-vec FreeBSD source bootstrap wiring detected"

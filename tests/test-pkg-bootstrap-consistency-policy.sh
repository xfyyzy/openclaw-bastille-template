#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
BOOTSTRAP_SCRIPT="${ROOT}/usr/local/libexec/openclaw/bootstrap-pkg.sh"
README_DOC="${ROOT}/README.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if ! rg -n --fixed-strings "phase2_conflict_origins='graphics/ImageMagick7 graphics/vips www/chromium www/firefox'" "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing conflict-prone browser/graphics origin split list in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings 'maybe_proxy "${pkg_cmd}" install -yn ${phase2_build_origins}' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing batch dry-run install step for conflict-prone origins in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings 'maybe_proxy "${pkg_cmd}" install -y ${phase2_build_origins}' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing batch apply install step for conflict-prone origins in bootstrap-pkg.sh"
fi

if rg -n --fixed-strings 'phase 3: dry-run ${_origin} to show conflict/replacement details' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "phase 3 should not dry-run conflict-prone origins one by one"
fi

if ! rg -n --fixed-strings 'summarize_conflict_chain_from_log()' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing conflict-chain summary parser in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings 'phase 3: conflict chain summary for' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing grouped conflict-chain summary output in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings 'maybe_proxy "${pkg_cmd}" info -r "${_pkg}"' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing reverse-dependency summary command for conflict packages in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings "pkg install consistency check failed: missing origins after install (" "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing strict post-install consistency failure message in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings "maybe_proxy \"\${pkg_cmd}\" query -a '%o'" "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing installed-origin query in bootstrap-pkg.sh consistency check"
fi

if ! rg -n --fixed-strings "sed 's/@.*$//'" "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing flavor normalization in bootstrap-pkg.sh consistency check"
fi

if ! rg -n --fixed-strings 'comm -23 "${_need_file}" "${_have_file}" > "${_missing_file}"' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing comm-based missing-origin diff in bootstrap-pkg.sh consistency check"
fi

if ! rg -n --fixed-strings 'verify_required_origins_installed "${bootstrap_origins}" "bootstrap origins"' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing bootstrap-origin consistency guard in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings "phase 4: retrying missing build origins individually" "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing per-origin retry path for missing build origins in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings "installs conflict-prone browser/graphics origins" "${README_DOC}" >/dev/null 2>&1; then
  fail "missing conflict-prone browser/graphics install note in README.md"
fi

if ! rg -n --fixed-strings "consistency check verifies both bootstrap origins and every derived build origin are installed" "${README_DOC}" >/dev/null 2>&1; then
  fail "missing post-install consistency-check note in README.md"
fi

echo "PASS: pkg bootstrap conflict split + consistency policy detected"

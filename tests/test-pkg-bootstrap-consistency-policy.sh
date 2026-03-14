#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
BOOTSTRAP_SCRIPT="${ROOT}/usr/local/libexec/openclaw/bootstrap-pkg.sh"
README_DOC="${ROOT}/README.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if ! rg -n --fixed-strings 'phase 2: installing all build origins in a single transaction' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing one-shot batch install marker for build origins in bootstrap-pkg.sh"
fi

if ! rg -n --fixed-strings 'maybe_proxy "${pkg_cmd}" install -y ${build_origins}' "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
  fail "missing one-shot batch install command for build origins in bootstrap-pkg.sh"
fi

for deprecated in \
  'phase2_conflict_origins=' \
  'split_build_origins()' \
  'install_conflict_prone_origins()' \
  'summarize_conflict_chain_from_log()' \
  'print_reverse_dependency_summary_from_log()' \
  'retry_missing_build_origins_individually()' \
  'phase 4: retrying missing build origins individually'
do
  if rg -n --fixed-strings "${deprecated}" "${BOOTSTRAP_SCRIPT}" >/dev/null 2>&1; then
    fail "deprecated split/retry logic still present in bootstrap-pkg.sh: ${deprecated}"
  fi
done

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

if ! rg -n --fixed-strings 'installs all derived build/runtime origins in one batch transaction' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing one-shot batch-install policy note in README.md"
fi

if ! rg -n --fixed-strings 'deployment fails immediately if batch install or consistency checks fail' "${README_DOC}" >/dev/null 2>&1; then
  fail "missing immediate-failure policy note in README.md"
fi

if rg -n --fixed-strings 'conflict-prone browser/graphics origins' "${README_DOC}" >/dev/null 2>&1; then
  fail "README.md still mentions deprecated conflict-prone split policy"
fi

if rg -n --fixed-strings 'retries each missing origin individually' "${README_DOC}" >/dev/null 2>&1; then
  fail "README.md still mentions deprecated per-origin retry policy"
fi

echo "PASS: pkg bootstrap one-shot batch install + strict consistency policy detected"

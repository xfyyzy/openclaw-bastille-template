#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPORT_DIR=${REPORT_DIR:-"${ROOT}/reports"}

mkdir -p "${REPORT_DIR}"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}" >&2
    exit 2
  fi
}

for cmd in shellcheck gitleaks trufflehog detect-secrets jq; do
  require_cmd "${cmd}"
done

cd "${ROOT}"

snapshot_dir=$(mktemp -d -t openclaw-scan-snapshot.XXXXXX)
cleanup() {
  rm -rf "${snapshot_dir}"
}
trap cleanup EXIT

while IFS= read -r -d '' path; do
  # Scan only tracked filesystem entries present in working tree.
  if [ ! -f "${path}" ] && [ ! -L "${path}" ]; then
    continue
  fi
  mkdir -p "${snapshot_dir}/$(dirname "${path}")"
  cp -P "${path}" "${snapshot_dir}/${path}"
done < <(git ls-files -z)

shellcheck_targets=(
  ".githooks/pre-commit"
  ".githooks/pre-push"
  "openclaw-jailctl.sh"
  "scripts/install-git-hooks.sh"
  "scripts/openclaw-zfs-datasets.sh"
  "lib/config.sh"
  "usr/local/bin/openclaw"
  "usr/local/etc/rc.d/openclaw_gateway"
  "usr/local/etc/rc.d/openclaw_searxng"
  "usr/local/libexec/openclaw/bootstrap-pkg.sh"
  "usr/local/libexec/openclaw/install-openclaw.sh"
  "usr/local/libexec/openclaw/searxng-run.sh"
)

run_scan() {
  local name="$1"
  shift
  set +e
  "$@"
  local ec=$?
  set -e
  printf '%s\n' "${ec}" > "${REPORT_DIR}/${name}.exit"
}

run_scan shellcheck \
  shellcheck -x -S warning -e SC2034 "${shellcheck_targets[@]}" \
  > "${REPORT_DIR}/shellcheck.txt" 2>&1

run_scan gitleaks \
  gitleaks dir "${snapshot_dir}" --report-format json --report-path "${REPORT_DIR}/gitleaks.json" --exit-code 1 \
  > "${REPORT_DIR}/gitleaks.stdout.txt" 2> "${REPORT_DIR}/gitleaks.stderr.txt"

cat > "${REPORT_DIR}/.trufflehog-exclude" <<'EOF'
^\.git/
^reports/
EOF

run_scan trufflehog \
  trufflehog filesystem \
  --directory "${snapshot_dir}" \
  --json \
  --no-verification \
  --no-update \
  --exclude-paths "${REPORT_DIR}/.trufflehog-exclude" \
  --fail \
  > "${REPORT_DIR}/trufflehog.jsonl" 2> "${REPORT_DIR}/trufflehog.stderr.txt"

run_scan detect-secrets \
  detect-secrets scan --all-files "${snapshot_dir}" \
  > "${REPORT_DIR}/detect-secrets.baseline.json" 2> "${REPORT_DIR}/detect-secrets.stderr.txt"

detect_results=$(jq '.results | keys | length' "${REPORT_DIR}/detect-secrets.baseline.json")
if [ "${detect_results}" -gt 0 ]; then
  detect_gate_exit=1
else
  detect_gate_exit=0
fi
printf '%s\n' "${detect_gate_exit}" > "${REPORT_DIR}/detect-secrets-gate.exit"

shellcheck_issues=$(grep -E '^In .* line' -c "${REPORT_DIR}/shellcheck.txt" || true)
gitleaks_findings=$(jq 'length' "${REPORT_DIR}/gitleaks.json" 2>/dev/null || echo 0)
trufflehog_findings=$(grep -c '^{' "${REPORT_DIR}/trufflehog.jsonl" 2>/dev/null || true)
if [ -z "${trufflehog_findings}" ]; then
  trufflehog_findings=0
fi

{
  echo "shellcheck_exit=$(cat "${REPORT_DIR}/shellcheck.exit")"
  echo "gitleaks_exit=$(cat "${REPORT_DIR}/gitleaks.exit")"
  echo "trufflehog_exit=$(cat "${REPORT_DIR}/trufflehog.exit")"
  echo "detect_secrets_exit=$(cat "${REPORT_DIR}/detect-secrets.exit")"
  echo "detect_secrets_gate_exit=$(cat "${REPORT_DIR}/detect-secrets-gate.exit")"
  echo "shellcheck_issues=${shellcheck_issues}"
  echo "gitleaks_findings=${gitleaks_findings}"
  echo "trufflehog_findings=${trufflehog_findings}"
  echo "detect_secrets_results=${detect_results}"
} > "${REPORT_DIR}/scan-summary.txt"

cat "${REPORT_DIR}/scan-summary.txt"

overall=0
for exit_file in \
  shellcheck.exit \
  gitleaks.exit \
  trufflehog.exit \
  detect-secrets.exit \
  detect-secrets-gate.exit; do
  if [ "$(cat "${REPORT_DIR}/${exit_file}")" -ne 0 ]; then
    overall=1
  fi
done

exit "${overall}"

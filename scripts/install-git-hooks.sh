#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "${ROOT}"

if [ ! -f ".githooks/pre-commit" ] || [ ! -f ".githooks/pre-push" ]; then
  echo "required hook files are missing under .githooks/" >&2
  exit 1
fi

chmod +x .githooks/pre-commit .githooks/pre-push
git config core.hooksPath .githooks

echo "Installed git hooks path: $(git config --get core.hooksPath)"
echo "Hooks enabled:"
echo "  - pre-commit: staged secret scan (gitleaks/trufflehog/detect-secrets)"
echo "  - pre-push: full scan suite (scripts/security-scan.sh)"

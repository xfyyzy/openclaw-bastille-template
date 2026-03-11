#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
PKGLIST="${ROOT}/pkglist/openclaw-2026Q1.pkglist"
README_DOC="${ROOT}/README.md"
ASSISTANT_CONTRACT="${ROOT}/JAIL_ASSISTANT_ENV.md"
INSTALL_SCRIPT="${ROOT}/usr/local/libexec/openclaw/install-openclaw.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Tooling origins must be declared in pkglist.
if ! rg -n --fixed-strings 'devel/rustup-init' "${PKGLIST}" >/dev/null 2>&1; then
  fail "missing devel/rustup-init in pkglist"
fi

if ! rg -n --fixed-strings 'devel/sccache' "${PKGLIST}" >/dev/null 2>&1; then
  fail "missing devel/sccache in pkglist"
fi

# Template install should provide rustup command compatibility from rustup-init.
if ! rg -n --fixed-strings 'ln -sf /usr/local/bin/rustup-init /usr/local/bin/rustup' "${INSTALL_SCRIPT}" >/dev/null 2>&1; then
  fail "missing rustup compatibility symlink logic in install script"
fi

# Docs must clarify baseline scope and intentional omissions.
if ! rg -n --fixed-strings 'devel/rustup-init' "${README_DOC}" >/dev/null 2>&1; then
  fail "README missing rustup-init origin note"
fi

if ! rg -n --fixed-strings 'cargo-miri' "${README_DOC}" >/dev/null 2>&1; then
  fail "README missing cargo-miri boundary note"
fi

if ! rg -n --fixed-strings 'cargo-nextest' "${README_DOC}" >/dev/null 2>&1; then
  fail "README missing cargo-nextest boundary note"
fi

if ! rg -n --fixed-strings 'plain `bastille cmd ... env` shell does not guarantee this PATH order' "${README_DOC}" >/dev/null 2>&1; then
  fail "README missing PATH scope clarification"
fi

if ! rg -n --fixed-strings 'devel/rustup-init' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "assistant contract missing rustup-init origin note"
fi

if ! rg -n --fixed-strings '普通 `exec shell` 不保证该 PATH 顺序' "${ASSISTANT_CONTRACT}" >/dev/null 2>&1; then
  fail "assistant contract missing PATH scope clarification"
fi

echo "PASS: rust tooling origins and policy documentation detected"

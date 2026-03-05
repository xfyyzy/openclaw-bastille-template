# Assistant Context Proxy Boundary Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make in-jail proxy behavior driven by deploy-time `USE_PROXY` via a runtime flag file, and clarify developer-vs-assistant documentation boundaries without introducing live-mount restrictions.

**Architecture:** Add one persisted runtime context file under `/usr/local/etc/openclaw` during install so assistants can read `OPENCLAW_PROXY_ENABLED` directly in jail. Update assistant contract text to use that flag instead of location assumptions. Update README to document audience boundaries and the default snapshot contents as the assistant-facing source.

**Tech Stack:** POSIX shell, Bastille template render args, Markdown docs, ripgrep-based shell tests.

---

### Task 1: Add failing test for runtime proxy flag and doc boundaries

**Files:**
- Create: `tests/test-assistant-context-boundary-and-proxy-flag.sh`
- Test: `tests/test-assistant-context-boundary-and-proxy-flag.sh`

**Step 1: Write failing test**

```sh
# assert install-openclaw.sh writes runtime-context.env with OPENCLAW_PROXY_ENABLED
# assert JAIL_ASSISTANT_ENV.md references runtime-context.env and OPENCLAW_PROXY_ENABLED
# assert README.md includes a documentation boundary section
```

**Step 2: Run to verify FAIL**

Run: `sh tests/test-assistant-context-boundary-and-proxy-flag.sh`
Expected: FAIL (new contract strings/logic missing).

### Task 2: Implement runtime-context proxy flag generation

**Files:**
- Modify: `usr/local/libexec/openclaw/install-openclaw.sh`
- Test: `tests/test-assistant-context-boundary-and-proxy-flag.sh`

**Step 1: Minimal implementation**

```sh
runtime_context_path='${OPENCLAW_ETC_DIR}/runtime-context.env'
proxy_enabled='no'
[ "${use_proxy}" = "yes" ] && proxy_enabled='yes'
cat > "${runtime_context_path}" <<EOF_CTX
OPENCLAW_PROXY_ENABLED=${proxy_enabled}
EOF_CTX
```

**Step 2: Run test to verify PASS for script checks**

Run: `sh tests/test-assistant-context-boundary-and-proxy-flag.sh`
Expected: partial PASS after docs updates are also done.

### Task 3: Update assistant contract and README boundaries

**Files:**
- Modify: `JAIL_ASSISTANT_ENV.md`
- Modify: `README.md`

**Step 1: Assistant contract update**
- Replace location/network assumption wording with runtime-flag driven guidance.
- Add runtime context file path and usage snippet.
- Keep guidance assistant-actionable (status, start, proxy usage rules).

**Step 2: README boundary update**
- Add concise section describing audience split: host developers use README; assistant runtime contract comes from snapshot `JAIL_ASSISTANT_ENV.md`.
- Keep live mount behavior unchanged and un-restricted.

### Task 4: Verify all related tests and shell lint

**Files:**
- Test: `tests/test-no-preflight-flag.sh`
- Test: `tests/test-mirror-probe-config.sh`
- Test: `tests/test-searxng-post-deploy-autostart.sh`
- Test: `tests/test-assistant-context-boundary-and-proxy-flag.sh`

**Step 1: Run verification command**

Run: `sh tests/test-no-preflight-flag.sh && sh tests/test-mirror-probe-config.sh && sh tests/test-searxng-post-deploy-autostart.sh && sh tests/test-assistant-context-boundary-and-proxy-flag.sh && shellcheck usr/local/libexec/openclaw/install-openclaw.sh`
Expected: all PASS.

# SearXNG Post-Deploy Auto-Start Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure `openclaw-jailctl.sh --deploy` attempts to auto-start `openclaw_searxng` after template application, with non-blocking warning semantics on failure.

**Architecture:** Keep Bastille template behavior unchanged (`openclaw_searxng_enable=YES`) and add a host-side post-template runtime check in `openclaw-jailctl.sh`. The deploy flow will run an idempotent `status -> start -> status` sequence via `bastille cmd`, then continue deployment summary regardless of startup outcome. Documentation in both English and Chinese contract files is aligned to this behavior.

**Tech Stack:** POSIX shell (`sh`), Bastille jail commands, ripgrep-based shell tests, Markdown docs.

---

### Task 1: Add failing test for deploy-time auto-start contract

**Files:**
- Create: `tests/test-searxng-post-deploy-autostart.sh`
- Test: `tests/test-searxng-post-deploy-autostart.sh`

**Step 1: Write the failing test**

```sh
#!/bin/sh
set -eu

SCRIPT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/openclaw-jailctl.sh"

# Must contain deploy-time status/start guard for openclaw_searxng.
# Must contain warning text when startup probe fails.
```

**Step 2: Run test to verify it fails**

Run: `sh tests/test-searxng-post-deploy-autostart.sh`
Expected: FAIL because deploy flow does not yet include searxng auto-start probe.

### Task 2: Implement idempotent post-deploy auto-start in deploy flow

**Files:**
- Modify: `openclaw-jailctl.sh`
- Test: `tests/test-searxng-post-deploy-autostart.sh`

**Step 1: Write minimal implementation**

```sh
ensure_searxng_started_after_deploy() {
  if bastille cmd "${JAIL_NAME}" service openclaw_searxng status >/dev/null 2>&1; then
    return 0
  fi

  if bastille cmd "${JAIL_NAME}" service openclaw_searxng start >/dev/null 2>&1 && \
     bastille cmd "${JAIL_NAME}" service openclaw_searxng status >/dev/null 2>&1; then
    return 0
  fi

  echo "warning: openclaw_searxng is not running after deploy; ..." >&2
  return 0
}
```

**Step 2: Run test to verify it passes**

Run: `sh tests/test-searxng-post-deploy-autostart.sh`
Expected: PASS.

### Task 3: Update docs and assistant contract to match runtime behavior

**Files:**
- Modify: `README.md`
- Modify: `JAIL_ASSISTANT_ENV.md`

**Step 1: Update “One-shot deployment” quick check wording**
- Remove language implying manual first-start is required.
- Keep status/check commands as operational diagnostics.

**Step 2: Update SearXNG behavior section**
- Replace “may not start on first deploy” with “deploy script attempts auto-start after template application.”
- Clarify failure path: non-blocking warning + manual recovery commands.

### Task 4: Verify full change set

**Files:**
- Test: `tests/test-no-preflight-flag.sh`
- Test: `tests/test-mirror-probe-config.sh`
- Test: `tests/test-searxng-post-deploy-autostart.sh`

**Step 1: Run verification commands**

Run: `sh tests/test-no-preflight-flag.sh && sh tests/test-mirror-probe-config.sh && sh tests/test-searxng-post-deploy-autostart.sh`
Expected: all PASS.

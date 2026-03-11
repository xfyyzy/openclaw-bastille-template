# Local Boot Hook Strict Deploy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a new rc service that executes a fixed persistent boot script on jail startup, and run it once immediately after first `--deploy` with strict failure semantics.

**Architecture:** Introduce `openclaw_local_boot` as an independent rc service rendered by the template. The service executes `/usr/local/etc/openclaw/boot-local.sh` when present and skips cleanly when missing. In deploy flow, call `service openclaw_local_boot start` after template apply; if it fails, abort deployment with cleanup.

**Tech Stack:** POSIX shell (`sh`), FreeBSD `rc.subr`, Bastille template render/sysrc flow, shell-based `rg` tests, Markdown docs.

---

### Task 1: Add failing contract tests first (TDD red phase)

**Files:**
- Create: `tests/test-local-boot-hook-contract.sh`
- Test: `tests/test-local-boot-hook-contract.sh`

**Step 1: Write failing test**
- Assert `Bastillefile` renders/chmods/enables `openclaw_local_boot`.
- Assert deploy flow runs `service openclaw_local_boot start` after template apply.
- Assert deploy failure path includes strict fatal message for local boot hook failure.
- Assert rc script implements "missing script -> skip success" and "execution failure -> non-zero".

**Step 2: Run test to verify it fails**

Run: `sh tests/test-local-boot-hook-contract.sh`  
Expected: FAIL before implementation.

### Task 2: Implement minimal runtime changes (TDD green phase)

**Files:**
- Create: `usr/local/etc/rc.d/openclaw_local_boot`
- Modify: `Bastillefile`
- Modify: `openclaw-jailctl.sh`

**Step 1: Add rc service**
- Implement rc service with defaults:
  - `openclaw_local_boot_enable=NO`
  - `openclaw_local_boot_script=/usr/local/etc/openclaw/boot-local.sh`
- `start_cmd` behavior:
  - missing script: print skip message and return 0
  - present script: execute with `/bin/sh`
  - script exits non-zero: propagate failure (strict).

**Step 2: Wire template**
- Add `RENDER /usr/local/etc/rc.d/openclaw_local_boot`.
- Add execute bit in existing `chmod` line.
- Add `CMD sysrc openclaw_local_boot_enable=YES`.

**Step 3: Strict deploy-time immediate run**
- Add `ensure_local_boot_hook_started_after_deploy()` in `openclaw-jailctl.sh`.
- After `apply_template`, call this function before deployment summary.
- On failure, print clear fatal guidance and return non-zero so deploy aborts.

### Task 3: Update developer/agent docs

**Files:**
- Modify: `README.md`
- Modify: `JAIL_ASSISTANT_ENV.md`

**Step 1: README (developer-facing)**
- Document new rc service contract, persistent script path, strict deploy behavior, and manual recovery commands.

**Step 2: JAIL_ASSISTANT_ENV.md (agent-facing)**
- Add key path entry for `/usr/local/etc/openclaw/boot-local.sh`.
- Add behavior contract for startup execution and deploy-time strict execution.
- Add operational commands for service check and manual invocation.

### Task 4: Verification before completion

**Files:**
- Test: `tests/test-local-boot-hook-contract.sh`
- Test: `tests/test-no-preflight-flag.sh`
- Test: `tests/test-mirror-probe-config.sh`
- Test: `tests/test-searxng-post-deploy-autostart.sh`
- Test: `tests/test-assistant-context-boundary-and-proxy-flag.sh`
- Test: `tests/test-rust-state-baseline.sh`

**Step 1: Run verification command**

Run:
`sh tests/test-local-boot-hook-contract.sh && sh tests/test-no-preflight-flag.sh && sh tests/test-mirror-probe-config.sh && sh tests/test-searxng-post-deploy-autostart.sh && sh tests/test-assistant-context-boundary-and-proxy-flag.sh && sh tests/test-rust-state-baseline.sh`

Expected: all PASS.

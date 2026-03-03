# OpenClaw Bastille Template

## Host-side persistent directories

- `/usr/local/etc/openclaw`
- `/var/db/openclaw/state`
- `/var/db/openclaw/workspace`
- `/var/db/openclaw/data`

Host-side ZFS dataset lifecycle is managed by:

```sh
sudo ./scripts/openclaw-zfs-datasets.sh create
sudo ./scripts/openclaw-zfs-datasets.sh verify
# Safety: verify current datasets first, then dry-run destroy before real destroy.
sudo ./scripts/openclaw-zfs-datasets.sh destroy --yes --dry-run
# Danger: destroys zroot/openclaw recursively after explicit confirmation flag.
sudo ./scripts/openclaw-zfs-datasets.sh destroy --yes
```

## One-shot deployment

```sh
./openclaw-jailctl.sh --deploy
```

Other lifecycle actions:

```sh
./openclaw-jailctl.sh --preflight
./openclaw-jailctl.sh --stop
./openclaw-jailctl.sh --destroy
```

## Local Leak-Prevention Hooks

To block secret leaks before code leaves your machine, enable versioned hooks:

```sh
./scripts/install-git-hooks.sh
```

Hook behavior:

- `pre-commit`: scans staged content snapshot with `gitleaks`, `trufflehog`, and `detect-secrets`
- `pre-push`: runs full scan suite via `./scripts/security-scan.sh`

Required local tools:

- `shellcheck`
- `gitleaks`
- `trufflehog`
- `detect-secrets`
- `jq`

Manual run (same checks as CI):

```sh
./scripts/security-scan.sh
```

Environment prompt for in-jail assistants:

- `JAIL_ASSISTANT_ENV.md`

## Assistant context in jail

Hybrid mode (default profile A):

- default: curated template snapshot is copied into jail at `/usr/local/share/openclaw/context/template-snapshot`
- optional: host repo can be mounted read-only at `/usr/local/share/openclaw/context/repo-live`

Relevant configuration knobs:

- `OPENCLAW_CONTEXT_SNAPSHOT_ENABLE` (`yes|no`, default `yes`)
- `OPENCLAW_CONTEXT_SNAPSHOT_DIR` (default `/usr/local/share/openclaw/context/template-snapshot`)
- `OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE` (`yes|no`, default `no`)
- `OPENCLAW_CONTEXT_REPO_HOST` (default current template project root)
- `OPENCLAW_CONTEXT_REPO_DIR` (default `/usr/local/share/openclaw/context/repo-live`)

When live mount is enabled, preflight validates `OPENCLAW_CONTEXT_REPO_HOST` as an absolute existing host directory.

In `--deploy` mode, the script destroys any existing `openclaw` jail first, then recreates a fresh bridged VNET jail and applies the template.

Before running, make sure these host paths exist:

- `/usr/local/poudriere/data/packages/150amd64-2026Q1` (or override `LOCAL_PKG_REPO`)
- `/usr/local/etc/proxychains.conf` (or override `PROXYCHAINS_CONF_HOST`)

## Mirror presets and fallback

When using `PKG_SOURCE=mirror` or `PKG_SOURCE=mixed-mirror`, the template resolves mirror URL from `PKG_MIRROR_PRESET` by default:

- `official` -> `https://pkg.freebsd.org` (default)
- `aliyun` -> `https://mirrors.aliyun.com/freebsd-pkg`
- `ustc` -> `https://mirrors.ustc.edu.cn/freebsd-pkg`
- `nju` -> `https://mirrors.nju.edu.cn/freebsd-pkg`
- `custom` -> use `PKG_MIRROR_URL` exactly as configured

You can define backup mirrors via `PKG_MIRROR_FALLBACKS` (comma-separated URLs).  
Preflight checks probe `packagesite.pkg` and bootstrap package paths (`ports-mgmt/pkg` and, when proxy is enabled, `net/proxychains-ng`) and automatically select the first healthy mirror before jail creation.

This template installs OpenClaw from npm release artifacts only (`openclaw@latest` by default), using `npm`.
This avoids FreeBSD source-build breakpoints while keeping deployment deterministic.
`pkg` stage follows `PKG_SOURCE` policy (default is local poudriere), while npm artifact download still requires npm registry/network access.

## Why npm instead of pnpm

pnpm uses a content-addressable store (`node_modules/.pnpm/<hash>/...`) that produces
unstable real paths — the hash changes on every fresh install. Since the jail is rebuilt
from scratch on each deploy while `/usr/local/etc/openclaw/openclaw.json` persists on
the host, any plugin paths recorded in config would break after a rebuild.

npm installs packages directly into `node_modules/<pkg>/` with no symlink indirection,
so `realpath()` returns a stable path that survives jail rebuilds.

## npm build-script policy (FreeBSD)

The installer runs `npm install --ignore-scripts` to suppress all postinstall/build
scripts, then selectively runs `npm rebuild` for packages that need native compilation:

- `@whiskeysockets/baileys`
- `koffi`
- `protobufjs`
- `sharp`

All other packages (including `@discordjs/opus` and `node-llama-cpp`) have their
build scripts suppressed.

Template runtime pins `node-gyp` and `node-addon-api` as direct dependencies so `sharp` source-build can resolve them during install.
Installer exports `PYTHON`/`npm_config_python` to the detected Python executable so node-gyp does not depend on `python3`/`python` alias names.

Optional OpenClaw version pinning:

```sh
OPENCLAW_NPM_SPEC='openclaw@2026.2.26' ./openclaw-jailctl.sh --deploy
```

`[openclaw]: Applying template: local/openclaw...` is a progress log from Bastille. If it fails after that line, the real error is printed in the following lines.

## First-run initialization in jail (single path)

Do not use `openclaw setup --wizard` on FreeBSD. It can attempt gateway service installation and fail with `Gateway service install not supported on freebsd`.

Single supported init path:

```sh
bastille cmd openclaw openclaw onboard --flow manual --mode local --no-install-daemon
```

Equivalent rc helper (recommended):

```sh
bastille cmd openclaw service openclaw_gateway init
```

`openclaw_gateway init` is safe for first boot and rebuilds:

- If `/usr/local/etc/openclaw/openclaw.json` is missing/empty, it runs:
  - `openclaw setup --workspace /var/db/openclaw/workspace`
- First run (or forced run) executes interactive onboarding without daemon install:
  - `openclaw onboard --flow manual --mode local --no-install-daemon`
- On success, it writes init marker:
  - `/var/db/openclaw/state/.onboarded`
- Later `init` calls are no-op by default; re-run onboarding only with `force-init`.

The template seeds `/usr/local/etc/openclaw/openclaw.json` on first install (only when the file is missing), with:

- `agents.defaults.workspace = /var/db/openclaw/workspace`

Combined with the wrapper's fixed `OPENCLAW_CONFIG_PATH` and `OPENCLAW_STATE_DIR`, a rebuilt jail continues to use the same persisted config/state/workspace mounts without relying on command-line path flags.
Wrapper routing policy is command-aware and config-driven:

- Main switch first: if template proxy switch is disabled (`USE_PROXY!=yes`), wrapper never uses `proxychains`.
- When `USE_PROXY=yes`, wrapper loads persistent routing policy from `/usr/local/etc/openclaw/proxy-routing.conf`.
- Default policy keeps local control commands direct (for example `gateway`/`daemon`, `status`/`health`, `config`, `cron`, `tui`) and routes external-facing paths (for example `gateway run`, remote onboarding flags, npm plugin installs/updates) through `proxychains`.
- Direct path execution sanitizes inherited proxy preload variables (`LD_PRELOAD`, `PROXYCHAINS_*`) before launching Node, preventing loopback Gateway RPC failures caused by parent-shell proxychains injection.
- Wrapper applies a small built-in compatibility merge for critical local control commands, so stale persisted routing files from older jail versions do not silently regress local command routing.
- The default policy is version-controlled at `/usr/local/share/openclaw/defaults/proxy-routing.conf` and copied to `/usr/local/etc/openclaw/proxy-routing.conf` only when missing, so manual edits survive jail rebuilds.

Proxychains loopback note (important for assistant-integrated local RPC calls that may not use `/usr/local/bin/openclaw`):

```conf
# host file mounted into jail as /usr/local/etc/proxychains.conf
# Place these lines in the global/options area, BEFORE [ProxyList].
localnet 127.0.0.0/255.0.0.0
localnet ::1/128

[ProxyList]
# Keep only proxy entries in this section (socks4/socks5/http),
# do not place `localnet` here.
# socks5 127.0.0.1 7890
```

If you update host `proxychains.conf`, restart or rebuild the jail (or at minimum restart the affected long-running assistant/gateway processes) so new processes pick up the updated rules.

Stateful CLI baseline (XDG, applies to all XDG-aware tools including `gh`):

- `XDG_CONFIG_HOME=/var/db/openclaw/state/xdg/config`
- `XDG_CACHE_HOME=/var/db/openclaw/state/xdg/cache`
- `XDG_STATE_HOME=/var/db/openclaw/state/xdg/state`
- Baseline is injected by template runtime for `openclaw` wrapper and `openclaw_gateway` service, so assistant-executed shell commands inherit it without per-tool wrappers.

Because these paths live under the persisted `state` mount, CLI auth/session/config data survive jail rebuilds.

## Gateway rc script in jail

Template installs `/usr/local/etc/rc.d/openclaw_gateway` and sets `openclaw_gateway_enable=YES`.
Gateway start is guarded by init marker by default (`openclaw_gateway_autostart_if_initialized=YES`):

- if `${openclaw_gateway_init_marker}` exists (default `/var/db/openclaw/state/.onboarded`), service starts automatically on jail boot;
- if marker is missing, start is skipped with guidance to run `service openclaw_gateway init`.

Gateway stop uses a bounded shutdown path: send `TERM`, wait up to `openclaw_gateway_stop_timeout`,
then escalate to `KILL` for supervisor and descendant processes. This prevents indefinite jail stop hangs.

Common lifecycle commands:

```sh
bastille cmd openclaw service openclaw_gateway check
bastille cmd openclaw service openclaw_gateway init
bastille cmd openclaw service openclaw_gateway force-init
bastille cmd openclaw service openclaw_gateway start
bastille cmd openclaw service openclaw_gateway status
bastille cmd openclaw service openclaw_gateway restart
bastille cmd openclaw service openclaw_gateway stop
```

Log inspection:

```sh
bastille cmd openclaw tail -f /var/log/openclaw_gateway.log
```

Optional rc overrides:

```sh
bastille cmd openclaw sysrc openclaw_gateway_user=root
bastille cmd openclaw sysrc openclaw_gateway_cmd_flags='gateway'
bastille cmd openclaw sysrc openclaw_gateway_daemon_flags=''
bastille cmd openclaw sysrc openclaw_gateway_child_pidfile='/var/run/openclaw/openclaw_gateway.child.pid'
bastille cmd openclaw sysrc openclaw_gateway_config='/usr/local/etc/openclaw/openclaw.json'
bastille cmd openclaw sysrc openclaw_gateway_workspace='/var/db/openclaw/workspace'
bastille cmd openclaw sysrc openclaw_gateway_init_marker='/var/db/openclaw/state/.onboarded'
bastille cmd openclaw sysrc openclaw_gateway_autostart_if_initialized=YES
bastille cmd openclaw sysrc openclaw_gateway_init_flags='onboard --flow manual --mode local --no-install-daemon'
bastille cmd openclaw sysrc openclaw_gateway_stop_timeout='20'
bastille cmd openclaw sysrc openclaw_gateway_stop_grace='3'
bastille cmd openclaw sysrc openclaw_gateway_xdg_base='/var/db/openclaw/state/xdg'
bastille cmd openclaw sysrc openclaw_gateway_xdg_config_home='/var/db/openclaw/state/xdg/config'
bastille cmd openclaw sysrc openclaw_gateway_xdg_cache_home='/var/db/openclaw/state/xdg/cache'
bastille cmd openclaw sysrc openclaw_gateway_xdg_state_home='/var/db/openclaw/state/xdg/state'
```

Use `openclaw_gateway_cmd_flags` for OpenClaw subcommands. Keep daemon-level options in `openclaw_gateway_daemon_flags`.

Force a one-time re-init:

```sh
bastille cmd openclaw service openclaw_gateway force-init
```

## SearXNG in jail

- Template installs `www/py-searxng-devel` and enables `openclaw_searxng` rc service by default.
- Service is configured for local-only access at `http://127.0.0.1:8888` (inside jail).
- Startup wrapper enforces `SEARXNG_BIND_ADDRESS=127.0.0.1` and `SEARXNG_PORT=8888`.
- `openclaw_searxng` starts automatically when the jail boots.
- First deploy seeds persistent config at `/usr/local/etc/openclaw/searxng.yml` when the file is missing:
  - `use_default_settings: true`
  - `search.formats: [html, json]`
  - disables known-missing engines in current `py-searxng-devel` package (`wikidata`, `ahmia`, `torch`, `yacy images`) to avoid runtime `500`
  - `server.bind_address: 127.0.0.1`
  - `server.port: 8888`
  - random `server.secret_key`
  - `server.limiter: false` (no Valkey required for local-only assistant use)
- Runtime log path is persistent: `/var/db/openclaw/state/searxng.log`.

Common lifecycle commands:

```sh
bastille cmd openclaw service openclaw_searxng status
bastille cmd openclaw service openclaw_searxng start
bastille cmd openclaw service openclaw_searxng restart
bastille cmd openclaw tail -f /var/db/openclaw/state/searxng.log
```

In-jail API check:

```sh
bastille cmd openclaw curl -fsS 'http://127.0.0.1:8888/search?q=freebsd&format=json' | head
```

Proxy behavior:

- When `USE_PROXY=yes`, SearXNG is started through `proxychains`, so outbound search traffic follows the same proxy policy.
- Local assistant calls to `127.0.0.1:8888` do not need explicit proxy wrapping.

## pkg policy

- Package source is controlled by `PKG_SOURCE`: `local`, `remote`, `mixed`, `mirror`, `mixed-mirror`.
- `local`/`mixed`/`mixed-mirror` use the host-mounted poudriere repo at `/mnt/poudriere`.
- `mirror`/`mixed-mirror` can use `PKG_MIRROR_PRESET` + `PKG_MIRROR_FALLBACKS`; preflight picks a healthy mirror before deployment.
- Bootstrap package set stays unchanged (`pkg`, `proxychains-ng` when enabled, `python`, `node`) regardless of source mode.
- Single source of truth: `pkglist/openclaw-2026Q1.pkglist` (pure origins, one per line).
- Poudriere consumes that file directly.
- `openclaw-jailctl.sh` reads the same file and derives build/runtime origins by excluding bootstrap origins (`ports-mgmt/pkg net/proxychains-ng lang/python311 www/node25` by default; override with `BOOTSTRAP_ORIGINS`).
- Curated jail context snapshot is copied to `OPENCLAW_CONTEXT_SNAPSHOT_DIR` (default `/usr/local/share/openclaw/context/template-snapshot`) and currently contains `JAIL_ASSISTANT_ENV.md`, `Bastillefile`, and `pkglist/`.
- Runtime installed package state should be queried directly in jail (for example: `pkg query '%o %n %v' | sort`).

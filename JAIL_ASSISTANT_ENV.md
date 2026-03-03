# OpenClaw Jail Assistant Environment Contract

## 1. 环境概览
- 当前环境运行在 FreeBSD jail 内。
- OpenClaw 运行入口为 `/usr/local/bin/openclaw`。

## 2. 重建模型与数据持久化
- 环境部署流程包含“销毁已有 jail + 创建新 jail”。
- 以下路径为宿主机持久化挂载点，jail 重建后继续复用同一份数据：
  - `/usr/local/etc/openclaw`
  - `/var/db/openclaw/state`
  - `/var/db/openclaw/workspace`
  - `/var/db/openclaw/data`
- 除上述持久化挂载点外，其余 jail 内文件系统路径都应视为可丢弃（重建后不保留）。

## 3. 关键路径
- 配置文件：`/usr/local/etc/openclaw/openclaw.json`
- OpenClaw 代理分流策略（持久化）：`/usr/local/etc/openclaw/proxy-routing.conf`
- OpenClaw 代理分流默认模板（仓库版本控制）：`/usr/local/share/openclaw/defaults/proxy-routing.conf`
- 状态目录：`/var/db/openclaw/state`
- Gateway 初始化标记（持久化）：`/var/db/openclaw/state/.onboarded`
- 工作区目录：`/var/db/openclaw/workspace`
- 持久化数据目录：`/var/db/openclaw/data`
- SearXNG 配置（持久化）：`/usr/local/etc/openclaw/searxng.yml`
- SearXNG 日志（持久化）：`/var/db/openclaw/state/searxng.log`
- SearXNG 本地入口（仅 jail 内可访问）：`http://127.0.0.1:8888`
- 模板上下文快照目录（默认存在）：`/usr/local/share/openclaw/context/template-snapshot`
  - `JAIL_ASSISTANT_ENV.md`（本文件）
  - `Bastillefile`
  - `pkglist/`
- 可选 live repo 挂载目录（仅在启用时存在）：`/usr/local/share/openclaw/context/repo-live`

## 3.1 模板上下文可见性
- 默认会注入精选模板快照到 `OPENCLAW_CONTEXT_SNAPSHOT_DIR`。
- 仅当宿主启用了 `OPENCLAW_CONTEXT_LIVE_MOUNT_ENABLE=yes` 时，才会把宿主仓库以只读方式挂载到 `OPENCLAW_CONTEXT_REPO_DIR`。
- 若两者同时存在，建议优先阅读快照（稳定），需要实时对照时再读取 live mount。

## 3.2 信息检索入口（按优先级）
- 第一步：先读取快照中的本文件（保证和当前 jail 构建一致）：
  - `cat "${OPENCLAW_CONTEXT_SNAPSHOT_DIR:-/usr/local/share/openclaw/context/template-snapshot}/JAIL_ASSISTANT_ENV.md"`
- 第二步：读取当前 jail 使用的模板声明与包白名单：
  - `cat "${OPENCLAW_CONTEXT_SNAPSHOT_DIR:-/usr/local/share/openclaw/context/template-snapshot}/Bastillefile"`
  - `find "${OPENCLAW_CONTEXT_SNAPSHOT_DIR:-/usr/local/share/openclaw/context/template-snapshot}/pkglist" -type f -maxdepth 2`
- 第三步：查询“当前实际已安装包”（实时状态）：
  - `pkg info`
  - `pkg query '%o %n %v' | sort`
- 如需宿主实时仓库上下文（仅在启用时）：
  - `[ -d "${OPENCLAW_CONTEXT_REPO_DIR:-/usr/local/share/openclaw/context/repo-live}" ] && ls -la "${OPENCLAW_CONTEXT_REPO_DIR:-/usr/local/share/openclaw/context/repo-live}"`

## 3.3 SearXNG（本地检索服务）
- 模板默认安装 `SearXNG` 并注册 rc 服务：`openclaw_searxng`。
- 服务启动后监听 `127.0.0.1:8888`，仅供 jail 内助手本地调用。
- 启动包装脚本会强制导出 `SEARXNG_BIND_ADDRESS=127.0.0.1` 与 `SEARXNG_PORT=8888`，避免被外部监听配置误改。
- 常用检查命令：
  - `service openclaw_searxng status`
  - `service openclaw_searxng restart`
  - `tail -f /var/db/openclaw/state/searxng.log`
- API 连通性示例：
  - `curl -fsS 'http://127.0.0.1:8888/search?q=freebsd&format=json' | jq '.results[0:3]'`
- 助手侧统一调用（推荐走 `exec`）：
  - `searxng_search "freebsd jail"`
  - `searxng_search --limit 5 --language zh-CN "openclaw 模板"`
  - `searxng_search --raw "freebsd"`（查看原始 SearXNG JSON）
- `searxng_search` 输出字段（稳定结构）：
  - `schema_version`, `ok`, `source`, `base_url`, `query`, `page`
  - `limit_applied`, `raw_results_count`, `results_count`, `number_of_results_reported`
  - `results[]`（统一字段：`rank`, `title`, `url`, `snippet`, `engine`, `category`, `published_date`, `score`）
  - `suggestions`, `answers`, `unresponsive_engines`
- 计数字段说明：
  - `results_count` 表示当前返回并标准化后的结果条数（助手应优先使用该字段）。
  - `number_of_results_reported` 来自上游聚合统计，可能为 `0` 但 `results_count > 0`，这不代表检索失败。
- 代理行为：
  - 当模板启用 `USE_PROXY=yes` 时，`openclaw_searxng` 会通过 `proxychains` 启动，SearXNG 对外检索流量自动走代理。
  - 访问 `127.0.0.1:8888` 这种 jail 内本地请求不需要额外加 `proxychains`。

## 3.4 Gateway（OpenClaw 主服务）
- rc 服务名：`openclaw_gateway`
- 默认行为：`openclaw_gateway_enable=YES`，且仅在初始化标记存在时自动启动。
  - 存在 `/var/db/openclaw/state/.onboarded`：jail 启动时自动拉起 Gateway
  - 缺失标记：跳过启动，并提示先执行 `service openclaw_gateway init`
- 常用命令：
  - `service openclaw_gateway status`
  - `service openclaw_gateway init`
  - `service openclaw_gateway force-init`
  - `service openclaw_gateway restart`

## 4. 网络访问约束
- 宿主机位于 China，默认无法直接访问国际互联网（或可达性不稳定）。
- jail 内提供 `proxychains`；访问国际互联网时请使用：
  - `proxychains -q <command>`
- 常见示例：
  - `proxychains -q git clone <repo>`
  - `proxychains -q curl -I https://example.com`
  - `proxychains -q uv pip install <package>`
- 纯本地操作（文件读写、本地构建、本地服务访问）不需要加 `proxychains`。
- 该规则主要用于 shell 中直接执行的外网命令；`openclaw` 命令采用“按命令路由”的代理策略：
  - 主开关优先：当模板代理开关不是 `USE_PROXY=yes` 时，`openclaw` 不会走 `proxychains`，也不会应用命令分流。
  - 仅在 `USE_PROXY=yes` 时，`openclaw` 才会读取 `/usr/local/etc/openclaw/proxy-routing.conf` 做按命令分流。
  - 当持久化策略文件缺失时，会从 `/usr/local/share/openclaw/defaults/proxy-routing.conf` 首次复制。
  - 默认策略下，本地控制/UX 命令（如 `gateway`、`daemon`、`status`、`health`、`config`、`cron`、`tui`）不走代理；明确需要外网的执行路径会走代理。
  - `onboard` 在使用远程相关参数（如 `--mode` / `--remote-url` / `--remote-token`）时会走代理。

## 5. Python 与 uv 约定
- 统一入口：`python3`（对应 `python3.11`）。
- Python 项目默认使用 `uv` 管理虚拟环境与依赖：
  - `uv venv .venv`
  - `. .venv/bin/activate`
  - `uv pip install <package>`
  - （项目有 `pyproject.toml` / `uv.lock` 时）优先 `uv sync`
- 避免在系统级 Python 环境中直接安装依赖。

## 6. Git 提交身份
- 该 jail 可能被多位助手共用；不会预置全局 `git user.name` / `git user.email`。
- 在新仓库首次 `git commit` 前，助手需按自身身份主动配置 Git identity，否则可能出现 `Author identity unknown` 报错。
- 推荐优先配置仓库级 identity（仅作用于当前仓库）：
  - `git config user.name "<your-name>"`
  - `git config user.email "<your-email>"`

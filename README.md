# token_tracker（ttk）—— CodeBuddy CLI token 用量记录器

扫描 **CodeBuddy CLI** 的本地会话记录，按 天 / 调用方式 / 模型 聚合 token
用量，按 DeepSeek 官方峰谷价折算花销，并监控免费模型池的 429 限流。
提供 PowerShell 弹窗（Win+R 风格）与纯命令行两种用法。

## 数据源依赖（先读这段）

ttk **不安装也不依赖 cb / ccb 程序本身**——它只读取 CodeBuddy CLI 写在
`~/.codebuddy-cli/projects/` 下的会话记录（`*.jsonl`，含 `providerData.rawUsage`
的行）。

- **终端** = Windows Terminal 交互会话；**弹窗** = WinForms 弹窗驱动的
  headless 会话。两者是同一工具的两种调用方式，共写同一个目录，
  ttk 按 `sessionId` 前缀 `ccb-` 区分。
- 换一台电脑：只要那台电脑**用过 CodeBuddy CLI**（任意调用方式），数据就在，
  ttk 直接能跑；从没用过 → 空报告 + 明确提示，不会崩。
- 数据目录可覆盖（优先级从高到低）：

```bash
py -3.11 ttk.py --projects "D:/path/to/projects"   # 命令行参数
set TTK_PROJECTS=D:/path/to/projects               # 环境变量（持久）
```

- 暂不支持 Claude Code 的会话格式（`~/.claude/projects`，行内结构不同）。

## 快速开始

```bash
# 弹窗（Windows；整个文件夹可随意拷贝，run_ttk.cmd 用相对路径）
run_ttk.cmd            # 双击，或传天数：run_ttk.cmd 14

# 命令行（任意平台，Python 3.8+，纯标准库）
py -3.11 ttk.py                    # 增量扫描 + 报告（默认 7 天）
py -3.11 ttk.py --days 14          # 看 14 天
py -3.11 ttk.py --refresh          # 丢弃缓存全量重扫
py -3.11 ttk.py --update-prices    # 立即抓 DeepSeek 官方价
py -3.11 ttk.py --json             # 报告打到 stdout
```

弹窗内容：今日卡片（总量 / 花销 / 积分）、7 日堆叠柱状图（终端=蓝 / 弹窗=紫）、
明细表、会员回本横条、**今日免费模型额度面板**（ds / step 两根横条，
填充度 = max(请求比, token 比)，绿→琥珀→红，竖线为 warn 刻度）。

## 功能口径

### 计价（DeepSeek 峰谷价）

- 高峰：工作日 9:00–12:00、14:00–18:00（北京时间）；空闲价 = 高峰价一半。
- 每条请求按自身时间戳判峰谷，同日跨峰谷也准确。
- 模型别名与单价在 `prices.json`；`fetched_at` 超 7 天自动抓官方页，
  失败沿用旧价。
- 输入 = 缓存命中 + 未命中；输出 = completion_tokens。

### 429 限流监控（ds 与混元3 共用一个池）

- 扫描 `providerData.error.status == 429` 的行，按同文件最近的请求模型归因。
- **ds 与混元3（网关 id `hy3`）共用一个免费池**，合并归组到 `ds`；step 独立。
- `danger` = 当日已出现 ≥1 次 429（硬信号）；
  `warn` = 日累计 ≥ `warn_ratio` × 预估上限（重载日预警）。
- 429 是短时间 burst 触顶（回补速率桶），日聚合量不到 burst，
  所以 warn 用「日累计接近预估上限」而非 burst 量，避免误报。
- **所有阈值都在 `limits.json`**，改文件即可，无需动代码：
  `ds` / `step` 的 `req` + `tokens`，以及顶层 `warn_ratio`。

### 会员回本

`membership.json` 记录月费 / 汇率 / 下次调价（`next_effective` 到点自动切），
报告给出「本月 API 价值 − 会员费 = 已省」。模板：

```json
{
  "plan": "WorkBuddy Pro",
  "monthly_fee_usd": 7.0,
  "next_fee_usd": 10.0,
  "next_effective": "2026-11-01",
  "usd_cny": 7.15,
  "note": "会员按月付费；API 价值按 DeepSeek 官方价折算"
}
```

文件缺失时用内置兜底值；删掉 `membership.json` 即关闭该面板语义。

### 积分

非 DeepSeek 模型（`hy3` / `step-*`）不计 DS 花销，单列「平台模型调用次数」；
积分值取 `rawUsage.credit`（当前为 0，平台开始计分后自动出现）。

## 文件

| 文件 | 作用 |
|---|---|
| `ttk.py` | 扫描 + 聚合 + 计价 + 预警引擎（纯标准库） |
| `_ttk.ps1` | WinForms 弹窗（深色 / DPI 感知 / 自绘） |
| `run_ttk.cmd` | 弹窗启动器（`%~dp0` 相对路径，可整体拷贝） |
| `prices.json` | DeepSeek 价格表（超 7 天自动抓取） |
| `limits.json` | 免费池预估上限 + `warn_ratio`（**调参入口**） |
| `membership.json` | 会员费（个人数据，已 gitignore，见上方模板） |
| `ttk.cache.json` | 增量扫描缓存（运行时生成） |
| `ttk.report.json` | 弹窗读取的报告（每次运行重写） |
| `ttk.state.json` | 窗口位置 / 置顶状态 |
| `ttk.debug.log` | 启动 / DPI / 扫描日志（排查用） |

## 其它口径

- 去重：按 `messageId` 哈希，跨文件只计一次。
- 日期：时间戳按 UTC+8 落自然日。
- 会话文件被截断/重写时自动全量重扫。
- 弹窗 DPI 感知：按系统 DPI 整体缩放（坐标与字体同步）。

## License

MIT

---

# token_tracker (ttk) — CodeBuddy CLI token usage tracker

Scans local **CodeBuddy CLI** session records and aggregates token usage by
day / invocation-style / model, prices it at official DeepSeek peak/off-peak
rates, and watches the free-tier pools for 429 rate limits. Ships as a
PowerShell popup plus a pure CLI.

## Data source (read this first)

ttk does **not** install or depend on the cb / ccb programs — it only reads the
session records CodeBuddy CLI writes to `~/.codebuddy-cli/projects/`
(`*.jsonl` lines containing `providerData.rawUsage`).

- **terminal** = interactive Windows Terminal session; **popup** = headless
  session driven by the WinForms popup input. Both are invocation styles of the
  same tool, writing to the same directory; ttk tells them apart by the
  `sessionId` prefix `ccb-`.
- On another machine: as long as CodeBuddy CLI has been used there (any style),
  the data is present and ttk just works. Never used → empty report with a
  clear hint, no crash.
- Override the data directory (highest priority first):

```bash
py -3.11 ttk.py --projects "D:/path/to/projects"   # CLI flag
set TTK_PROJECTS=D:/path/to/projects               # env var
```

- Claude Code's session format (`~/.claude/projects`) is intentionally not
  supported (different line schema).

## Quick start

```bash
run_ttk.cmd            # popup on Windows; folder is relocatable
py -3.11 ttk.py                    # incremental scan + report (7 days)
py -3.11 ttk.py --days 14          # 14-day view
py -3.11 ttk.py --refresh          # full rescan, drop cache
py -3.11 ttk.py --update-prices    # fetch official prices now
py -3.11 ttk.py --json             # report to stdout
```

## Feature notes

- **Pricing**: peak = weekdays 09:00–12:00 & 14:00–18:00 (UTC+8); off-peak is
  half price. Each request is priced by its own timestamp. Prices auto-refresh
  weekly from the official page (falls back to the cached copy).
- **429 monitoring**: ds and Hunyuan3 (gateway id `hy3`) share one free pool
  and are grouped together as `ds`; step is separate. `danger` = any 429 today
  (hard signal); `warn` = daily usage ≥ `warn_ratio` × estimated ceiling.
  All thresholds live in `limits.json` — no code changes needed.
- **Membership break-even**: configure `membership.json` (template above);
  the popup shows API value vs. fee and how much you saved.
- **Credits**: non-DeepSeek models are counted separately as "platform model
  calls"; credit values come from `rawUsage.credit`.

## License

MIT

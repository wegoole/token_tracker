# token_tracker（ttk）—— CodeBuddy CLI token 用量记录器

扫描 **CodeBuddy CLI** 的本地会话记录，按 天 / 调用方式 / 模型 聚合 token
用量，按各模型的输入/缓存/输出 Token 单价估算花销，并监控免费模型池的 429 限流。
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

弹窗内容：今日卡片（Token 总量与上下行 / 模型估价 / 独立积分资产）、7 日堆叠柱状图（终端=蓝 / 弹窗=紫）、
**明细按钮**（每日各模型 Token 表 + 选中模型的逐项计价公式 + JSON 入口）、会员回本横条、**今日免费模型额度面板**（ds / step 两根横条，
填充度 = max(请求比, token 比)，绿→琥珀→红，竖线为 warn 刻度）。

## 功能口径

### 计价（按模型 Token 单价估算）

- 今日用量统一为 **Token**：输入 = 缓存命中 + 未命中 + 缓存写入；输出 = `completion_tokens`。
- 费用 = 每个模型的输入、缓存读写、输出 Token 分别乘对应单价；**积分不混入用量或费用**。
- 模型别名与单价在 `prices.json`；DeepSeek 每 7 天自动抓官方价，更新时保留其它模型价格。
- 未配置单价的模型仍统计 Token，但不计入费用，并在 CLI/弹窗中标记。

#### 定价口径（统一：官网刊例价）

所有模型**一律取厂商官网的「刊例价」（list price）**，不采用限时折扣、活动价、中转站转售价。

| 规则 | 说明 |
|---|---|
| 币种 | 人民币官网价**直接填**；美元官网价 **×7.15** 折算 |
| 缓存命中 | 官网公布则用官网价；未公布按 **输入价 ×10%** 估算 |
| 缓存写入 | 官网公布则用官网价（Kimi 取 5min TTL 档）；未公布按 **未命中输入价** 计 |
| 峰谷价 | DeepSeek 保留高峰/空闲双档，按每条请求时间戳判定（工作日 9–12、14–18 高峰） |
| 折扣 | 只写进 `source` 备注，**不参与计算**（例：GLM-5.3-Flash 限时五折 0.4/0.115/1.4 未采用，按 0.8/0.23/2.8 计） |
| 来源标注 | 每个模型 `source` 必须写明「官网刊例价 + 核对日期」，`prices.json` 顶层 `pricing_basis` 存总口径 |

> 官网页面常是动态表格，`WebFetch` 取不到数字时用 Brave 无头渲染（`chromium.launch(executable_path=Brave, headless=True)` 后读 `inner_text('body')`）。
> 中转站（[PackyAPI](https://www.packyapi.ai/pricing)）仅在官网确实无按量报价时兜底；其 `$` 是人民币符号，1 RMB = 1 标记美元，**直接 1:1 填，不乘汇率**。

### 每日模型明细（供复算与可视化）

`ttk.report.json` 的 `days[] → models[]` 已按「日期 × 模型」保存：
`req / tokens / in / hit / miss / write / out / cost / price_unit / price_source`。
其中 `breakdown[]` 进一步按 `hit / miss / write / out` 展开，每项包含：
`tokens / peak_tokens / off_tokens / peak_price / off_price / peak_cost / off_cost / cost`。
价格单位统一为 `CNY_per_1m_tokens`，可直接用于透视表、ECharts 或其它可视化。
弹窗顶栏「明细」可查看同一份数据的表格和完整计算过程。

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

`membership.json` 记录月费 / 折算汇率，报告给出「本月 API 价值 − 会员费 = 已省」。模板：

```json
{
  "plan": "WorkBuddy Pro",
  "monthly_fee_usd": 7.0,
  "usd_cny": 6.714,
  "note": "会员按月付费；API 价值按各模型 Token 单价估算，不含积分"
}
```

`usd_cny` 按**实付金额 ÷ 美元价**填（$7 实付 ¥47 → 6.714），这样「会员费」直接等于真实支出。

文件缺失时用内置兜底值；删掉 `membership.json` 即关闭该面板语义。

### 积分

积分值取 `rawUsage.credit`，仅用于积分消耗与矩阵资产展示；不再与 Token 相加，
也不折算进今日或本月估算费用。

### 6 通道矩阵的积分来源

| 通道 | 取数方式 |
|---|---|
| Target 1–5（web） | 读各 home 的 CLI `accessToken`，直连 `POST /billing/meter/get-user-resource-summary` |
| Target 6（api-key） | **主 Brave 的脚本猫油猴脚本回传**（见下）；备选 CDP 9222 |

Target 6 的 API Key 属于 **workbuddy.ai** 账号（`X-User-Id` 可验），额度只在网页控制台可见，
API Key 本身没有余额接口。所以用油猴脚本在页面里取：

- 脚本：`E:\ai tec\cb_login\wb_credit.user.js`（脚本猫 id `ndcooeab…`，v1.2+）
- 接收端：`E:\ai tec\cb_login\wb_credit_bridge.py`（`127.0.0.1:18777`，ttk 会自动拉起）
- 回传落盘：`E:\ai tec\cb_login\target6_credits.json`（`source=userscript`）
- 时效：**90 分钟内**的回传才算实时；超过则降级为「查询失败 + 陈旧快照」，且**不计入**总储备

装脚本：主 Brave 打开 `http://127.0.0.1:18777/userscript.user.js` → 脚本猫安装；页面右下角会出现「积分桥 已连接」徽标。

## 文件

| 文件 | 作用 |
|---|---|
| `ttk.py` | 扫描 + 聚合 + 计价 + 预警引擎（纯标准库） |
| `_ttk.ps1` | WinForms 弹窗（深色 / DPI 感知 / 自绘） |
| `run_ttk.cmd` | 弹窗启动器（`%~dp0` 相对路径，可整体拷贝） |
| `prices.json` | 各模型 Token 单价（DeepSeek 超 7 天自动抓取，其它模型保留） |
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
day / invocation-style / model, estimates cost from each model's input/cache/output
token rates, and watches the free-tier pools for 429 rate limits. Ships as a
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

- **Usage and pricing**: today's usage is tokens only. Input includes cache hits,
  misses and cache writes; output uses completion tokens. Cost is estimated per
  model from input/cache/output rates; credits are shown separately and never
  added to token usage or cost. DeepSeek keeps peak/off-peak pricing and weekly
  refreshes without discarding other models. PackyAPI is a reference source for
  models without public prices.
- **429 monitoring**: ds and Hunyuan3 (gateway id `hy3`) share one free pool
  and are grouped together as `ds`; step is separate. `danger` = any 429 today
  (hard signal); `warn` = daily usage ≥ `warn_ratio` × estimated ceiling.
  All thresholds live in `limits.json` — no code changes needed.
- **Membership break-even**: configure `membership.json` (template above);
  the popup shows API value vs. fee and how much you saved.
- **Credits**: credit values come from `rawUsage.credit` and remain a separate
  consumption/asset metric, not a token or currency input to the estimate.

## License

MIT

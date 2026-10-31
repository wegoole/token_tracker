# WORKFLOW —— token_tracker

1. **日常查看**：`run_ttk.cmd`（本机作者另设了 Win+R → `ttk` 快捷入口）。窗口默认置顶，Esc 关闭，位置自动记住。
2. **刷新**：点「刷新」；引擎增量读取新会话，状态行显示「正在汇总…」，完成后卡片/图表/表格一起更新。
3. **价格明细**：点顶栏「明细」查看每日各模型 Token 表；选中一行后，下方显示峰谷 Token × 单价的完整公式。「打开 JSON」可直接打开 `ttk.report.json`，路径为 `days[] → models[] → breakdown[]`，供后续可视化。
4. **会员费维护**：改价或实付金额变了改 `membership.json` 的 `monthly_fee_usd` / `usd_cny`（`usd_cny` = 实付人民币 ÷ 美元价），弹窗横条随之更新。
5. **价格维护**：`prices.json` 保存各模型输入/缓存读写/输出单价；DeepSeek 超过 7 天自动抓官方页（保留其它模型），也可手动 `py -3.11 ttk.py --update-prices`。**统一口径＝厂商官网刊例价**：人民币官网价直接填，美元价 ×7.15；不采用限时折扣/活动价/中转站价（折扣只写进 `source` 备注）。缓存命中未公布按输入 ×10%、缓存写入未公布按未命中输入价。官网确实没有才用 PackyAPI（其 `$` 按人民币 1:1，不乘汇率）。每条 `source` 写明「官网刊例价 + 核对日期」，总口径存 `pricing_basis`。
6. **数据异常**：
   - 表格为空 → 看 `ttk.debug.log` 与 `ttk.last.err.txt`；
   - 怀疑缓存脏 → `py -3.11 ttk.py --refresh`；
   - 数字对不上 → 用 `--json` 看逐日 `models` 明细。
7. **改版式**：只改 `_ttk.ps1`（自绘图表/表格，坐标以 96 DPI 逻辑单位写，乘 `$global:TTK.K`）。

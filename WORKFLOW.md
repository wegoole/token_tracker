# WORKFLOW —— token_tracker

1. **日常查看**：`run_ttk.cmd`（本机作者另设了 Win+R → `ttk` 快捷入口）。窗口默认置顶，Esc 关闭，位置自动记住。
2. **刷新**：点「刷新」；引擎增量读取新会话，状态行显示「正在汇总…」，完成后卡片/图表/表格一起更新。
3. **会员费维护**：调价或汇率变了改 `membership.json`（`next_effective` 到点自动切换），弹窗横条随之更新。
4. **价格维护**：`prices.json` 超过 7 天自动抓官方页；也可手动 `py -3.11 ttk.py --update-prices`。
5. **数据异常**：
   - 表格为空 → 看 `ttk.debug.log` 与 `ttk.last.err.txt`；
   - 怀疑缓存脏 → `py -3.11 ttk.py --refresh`；
   - 数字对不上 → 用 `--json` 看逐日 `models` 明细。
6. **改版式**：只改 `_ttk.ps1`（自绘图表/表格，坐标以 96 DPI 逻辑单位写，乘 `$global:TTK.K`）。

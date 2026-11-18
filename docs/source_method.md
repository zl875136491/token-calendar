# Token Calendar 用量数据来源

2026-11-18 在本机核验。首版采集 Codex（ChatGPT Plus 登录）、Cursor Pro 和 Google Antigravity（Google AI Pro）的额度。每个额度池以应用首次成功采样的数据为基线，后续记录新增消耗。

| 平台 | 本地入口和认证 | 5 小时额度 | 周额度 | 月额度 |
| --- | --- | --- | --- | --- |
| Codex | **实测** `codex app-server --listen stdio://` 的 `account/rateLimits/read`。复用 CLI 的 ChatGPT 登录态。按 `limitId`、`windowDurationMins`、`usedPercent`、`resetsAt` 读取。 | 300 分钟，已用百分比和重置时间。 | 10080 分钟，已用百分比和重置时间。 | — [Codex App Server](https://learn.chatgpt.com/docs/app-server#auth-endpoints) |
| Cursor Pro | **实测** 读取当前 CLI 保存的 macOS 钥匙串登录项，查询 Cursor 的客户端额度接口。CLI 的 `status` 和 `about` 可确认登录及套餐。 | 当前账号的 Grok Bot 接口只返回周周期。 [Grok Bot Usage & Billing](https://docs.x.ai/grok-bot/settings-and-notifications) | Grok Bot 周额度由 `DashboardService/GetSandUsageStatus` 返回。字段为 `usagePercent`、`currentPeriodStart`、`nextResetTimestampUtc`。 | `DashboardService/GetCurrentPeriodUsage` 返回 Cursor Models（`planUsage.autoPercentUsed`）、Other Models（`planUsage.apiPercentUsed`）及账期起止时间。现场返回 61.12% 和 12.24%，与 Spending 截图相符。 [Cursor Spending](https://cursor.com/dashboard/spending) |
| Google Antigravity | **实测** 本机 `agy` 的交互式 `/usage`，通过伪终端读取模型组标签、剩余百分比和刷新倒计时。 | Gemini Models、Claude and GPT models。 | Gemini Models、Claude and GPT models、Gemini 4 Argon。 | — [Antigravity `/usage`](https://antigravity.google/docs/cli/commands/usage) · [套餐](https://antigravity.google/docs/plans) |

## API 和网页核对

| 平台 | 可用接口 | 网页或桌面核对 |
| --- | --- | --- |
| Codex | 本机 App Server 使用 ChatGPT 订阅额度。 | [Codex Usage](https://chatgpt.com/codex/settings/usage) |
| Cursor | 已用现有 CLI 登录令牌实测 `https://api2.cursor.sh/aiserver.v1.DashboardService/` 的两个只读方法。它们是 Cursor 客户端使用的未公开接口。公开的 Team Admin API 面向有相应权限的团队。 | Spending 页显示两个模型月度池及 Grok Bot 周额度。截图中的 Grok Bot 已用 100%，实测当前周期为北京时间 11 月 13 日 11:44 至 11 月 20 日 11:44。 [Cursor Spending](https://cursor.com/dashboard/spending) · [Cursor Admin API](https://cursor.com/docs/account/teams/admin-api) |
| Antigravity | 当前使用已验证的本机 `/usage`。 | 桌面 Models & Usage 可核对套餐、模型组和剩余百分比。Google One 的 AI Credits 活动只对应额外 credits。 [Google One AI Credits](https://support.google.com/googleone/answer/16287445) |

## 采集口径

- 首次采样只记基线。应用开启期间每五分钟采集一次，也可手动刷新。重启后继续使用本机已有记录。
- SQLite 的 `meter`、`quota_window` 和 `daily_usage` 表分别保存额度池的最近读数、观测到的周期和每日用量。首次启动新版时导入旧版 JSON 记录。
- 界面显示官方当前累计用量，并以百分点表示应用观测到的新增用量。新增用量按检测到变化的采样日归属。重置前最后一次采样到重置之间的消费可能漏记。
- Cursor 给出周期起止时刻。Codex 的周期起点根据重置时间和周期长度计算。Antigravity 用采集时刻与倒计时估算边界，满额时界面可能只提供剩余量。
- Cursor 客户端接口或 Antigravity 终端格式变化时，应用在对应来源显示读取问题。Cursor 首次需要时由 macOS 提示允许读取 CLI 的钥匙串登录项。

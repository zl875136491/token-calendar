# Token Calendar

macOS 额度日历，跟踪 Codex、Cursor 和 Antigravity 的 5 小时、周和月额度。

## 启动

需要 macOS 14 或更新版本和 Swift 6 工具链。安装对应 CLI 并登录，然后从项目目录运行：

```sh
sh build-app.sh
open ".build/Token Calendar.app"
```

可用 `swift run TokenCalendar --check-sources` 检查三家的采集结果。Cursor 读取已登录 CLI 在 macOS 钥匙串中的访问令牌，并向 Cursor 自身的额度接口查询。系统弹出钥匙串授权时可按需允许。Cursor 使用未公开的客户端接口，Antigravity 使用 `agy /usage` 终端面板，升级后可能需要适配。

## 记录方式

每个额度池从首次成功读取时建立基线。应用运行时每五分钟采样一次，也可手动刷新。额度变化以百分点计，记在采样当天。平台给出的周期起止时间会显示在日历中，Antigravity 的倒计时会换算成估算时间。

额度池、周期和每日消耗保存在 `~/Library/Application Support/TokenCalendar/observations.sqlite3`。首次升级自动导入之前的 `observations.json`，原文件保留供恢复。重开应用后继续已有记录。采样间隔内的变化按采样日归属，历史日期或月份根据已记录的每日消耗显示。

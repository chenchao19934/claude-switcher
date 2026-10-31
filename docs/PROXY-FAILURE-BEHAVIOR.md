# macOS 代理异常时如何处理 Claude

本次快捷面板改造不修改核心检查、账号切换或保镖逻辑。以下是当前仓库的实际行为。

## 启动与切换之前

从界面点击 A–D 账号时，`VM.switchTo` 会先重新执行完整审计。代理内核、TUN、出口国家、保镖等硬性项未通过，或审计超时、退出失败、缺行、重复行时，不调用账号切换命令，也不启动 Claude。已有 Claude 进程的运行中保护由独立保镖负责。

这个完整预审计由 GUI 保证。直接执行 CLI 的 `claude-switch.sh switch B` 会直接进入 `switch_to`，当前没有等价的自动预审计；不要把它当作 GUI 的安全启动流程。此次按要求保持核心不动。

## Claude 已经在运行

安装并注册的 root LaunchDaemon `local.claude-bodyguard` 以 `StartInterval=10` 调度保镖，检查对应代理客户端进程与 `198.18.*` TUN 地址。发现代理内核退出或 TUN 消失时，执行：

```bash
pkill -f '/Applications/Claude.app/Contents/MacOS/Claude'
```

这是默认 SIGTERM 终止请求，不是强制 `SIGKILL`，脚本也没有等待并确认最终退出。10 秒是调度配置，不是异常后必定在 10 秒内完成的承诺。它直接匹配 Claude 桌面主进程，不直接覆盖浏览器、Claude Code CLI 或所有 Helper。

## 账号、登录态和快照

保镖不切换账号、不主动注销登录、不清空 Claude 数据，也不交换或删除 `accounts/A–D` 快照。它只请求终止桌面进程并记录脱敏日志。当前登录资料通常会留在原数据目录，但尚未保存的草稿、正在生成的回复或未落盘状态可能中断，不能保证所有会话数据均已保存。

正常账号交换仅在明确发起切换后发生，走原有退出、归档与恢复流程；不要为了处理代理异常删除账号数据或快照。

## 节点失败与防护边界

若节点连接失败、请求超时，但内核进程与 TUN 仍存在，保镖不会仅因此退出 Claude；它不做实时出口国家、节点可达性或远端账号状态探测。下一次界面审计可能发现出口或生态可达性异常并阻断启动／切换。

菜单栏与通知中心展示的是最近一次界面检查结果，不等于代理正在实时可用。小组件超过 30 分钟会提示结果已过期；实际保护依赖已安装的后台服务与代理配置。隔离演示的假检查不能证明这些真实保护已运行。

保镖是进程级急停，存在巡检与退出之间的时间窗口，不是防火墙级零泄漏保证。完整边界见 [SECURITY.md](../SECURITY.md)。

源码依据：`app/main.swift` 的 `VM.switchTo`、`core/claude-switch.sh` 的 `check/checkdetail/switch_to`、`daemons/claude-bodyguard.sh` 与 `daemons/local.claude-bodyguard.plist`。

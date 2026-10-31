# macOS 通知中心状态小组件

小组件使用原生 WidgetKit，支持小号和中号，显示当前 A–D 账号槽位、最近一次环境检查的结果与通过／警告／失败／跳过数量。点击卡片通过 `claude-switcher://panel` 呼出快捷面板。

它只读取主应用写入的脱敏摘要，不运行检查、不访问账号目录、不包含 IP 或检查详情。卡片始终标注「最近检查，非实时」；超过 30 分钟的结果显示「结果已过期」，未检查或数据无效时不会显示通过。WidgetKit 控制刷新时机，主应用会在摘要变化后请求刷新；它不是保镖或实时监控的替代品。

## 本地编译验证

```bash
bash scripts/build-macos-widget.sh --compile-only
```

产物为 `build/widget/ClaudeSwitcherStatus.appex`。此模式只编译与 ad-hoc 签名验证，不指定虚构 App Group，不注册系统扩展，也不安装本机 App。编译通过不代表通知中心或跨进程共享状态已完成验收。

## 构建可用的签名版本

通知中心小组件作为独立扩展嵌入主 App；主 App 与扩展需要由同一个真实开发团队签名，并声明同一个 App Group。这个项目使用 macOS 支持的 `<Developer Team ID>.<组名>` 格式，签名时核对证书中的 TeamIdentifier；不使用虚构 Team ID 或绕过共享容器权限。

推荐在生成 ZIP／DMG 前一并嵌入，在仓库内执行：

```bash
WIDGET_SIGN_IDENTITY='你的真实签名身份' \
WIDGET_APP_GROUP='你的10位TeamID.claude-switcher' \
bash scripts/package-macos.sh 0.0.0-dev
```

也可以先构建正式 App，再单独嵌入：

```bash
bash scripts/package-macos.sh 0.0.0-dev
bash scripts/build-macos-widget.sh \
  --embed "$PWD/build/Claude切换器.app" \
  --identity '你的 Apple Development 或 Developer ID Application 签名身份' \
  --app-group '你的10位TeamID.claude-switcher'
```

上面的身份与组名是说明占位符，必须替换为真实值。脚本只接受仓库 `build/` 内的 App，不接受桌面或 `/Applications` 中的安装版本。它先在工作副本中嵌入、签名、校验，再替换构建产物；失败保留原 App。扩展启用 App Sandbox，主 App 保留原有权限并添加 App Group 权限。

单独执行嵌入后，之前生成的 ZIP／DMG 不会自动更新；需要从已嵌入的 App 重新打包。发布流程可在生成归档前调用此脚本。

系统使用小组件前，需要安装并至少启动一次包含扩展的主 App，再从 macOS「编辑小组件」中选择「Claude 状态」。对维护者本机进行安装或替换前，仍需遵守 AGENTS.md 的当次明确授权要求。

## 共享摘要协议

主 App 与扩展的 Info.plist 使用 `ClaudeSwitcherAppGroup` 指定组名。在 `UserDefaults(suiteName: 组名)` 下，以 Data 类型的 `statusSnapshot` 保存 JSON：

```json
{
  "schemaVersion": 1,
  "currentAccount": "A",
  "status": "ready",
  "checkedAt": 1793433600,
  "passed": 13,
  "warning": 1,
  "failed": 0,
  "skipped": 0,
  "pending": 0
}
```

`status` 是界面阶段字符串：`checking`、`ready`、`failed`、`fixing`、`switching`、`done` 或 `unknown`。`checkedAt` 为最近检查时间的 Unix 秒，0 表示没有完成过检查。五类计数均为 0–14 整数且合计为 14。扩展拒绝未知 schema、额外字段、非法账号／状态、非法或未来时间和无效计数。主 App 写入后请求 `WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeSwitcherStatusWidget")`。

## 验收范围

需要实际签名与图形会话验证：小组件库发现、小号／中号布局、首次等待态、主 App 更新后刷新、过期提示，以及点击卡片呼出面板。没有可用签名身份时只能报告编译和隔离模型验证，不能声称系统小组件已安装或可用。

官方参考：[创建 Widget 扩展](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)、[配置 App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)、[macOS 共享容器权限](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)、[Widget 刷新机制](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)。

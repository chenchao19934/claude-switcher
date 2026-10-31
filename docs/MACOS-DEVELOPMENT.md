# macOS 开发环境

项目的 macOS 应用由 SwiftUI / AppKit 界面、Bash 核心和 Python STUN 探针组成。没有 Xcode 工程、Swift Package 或 npm 应用依赖。最低部署目标为 macOS 13，构建默认使用当前 Mac 的架构。

## 开始开发

安装 Xcode Command Line Tools（已有则跳过）：

```bash
xcode-select --install
```

在仓库根目录运行：

```bash
bash scripts/dev-macos.sh doctor
bash scripts/dev-macos.sh run
```

`doctor` 检查本地工具，不联网。Swift 编译器和 macOS SDK 由 Command Line Tools 提供；Python 测试只使用标准库，无需虚拟环境或 pip 安装。UI 构建不需要 Node；运行完整 `test` 则需要 Node 来执行 JavaScript 规则回归。

`run` 每次从源码重新构建 `build/dev/MenuBarFixture` 和 `build/dev/ClaudeSwitcherDemo.app`，启动带「隔离演示」标题的原生快捷面板。它复用生产视图、菜单与模型，显式注入 `tests/fixtures/macos-dev-core.sh`，不调用已安装核心脚本。14 项结果都标注为假数据，其中 ASN 默认显示警告；这些结果不代表真实环境已经通过审计。

可以调试菜单栏、窗口、A–D 模拟账号切换、代理客户端选择和检查设置。模拟状态只存储在 `build/dev/demo-state.json`；真实 Claude、账号目录、代理配置与系统服务不参与。更新检查只显示演示提示；诊断导出等未模拟命令会明确失败。

其他常用命令：

```bash
bash scripts/dev-macos.sh run --dark
bash scripts/dev-macos.sh run --hotkey
bash scripts/dev-macos.sh build
bash scripts/dev-macos.sh test
bash scripts/dev-macos.sh widget
```

默认演示不注册系统快捷键；`--hotkey` 仅为这次演示进程注册全局快捷键，进程退出后释放。演示的快捷键偏好只存内存，不写正式应用偏好，也不写 Widget 共享容器。主面板内的快捷键操作无需系统注册也可使用。

关闭面板后应用仍驻留菜单栏。从菜单栏右键选择「退出 Claude 切换器」，再重新运行 `run` 加载新代码。需要重置模拟账号与检查设置时，退出演示后删除 `build/dev/demo-state.json`。`widget` 只编译独立扩展，不安装或注册系统小组件。

## 构建正式应用与分发包

```bash
bash scripts/dev-macos.sh package 0.0.0-dev
# 等价于：bash scripts/package-macos.sh 0.0.0-dev
```

产物在 `build/`：

- `Claude切换器.app`：正式界面应用。
- `ClaudeSwitcher-<版本>-macos-<架构>-app-only.zip` / `.dmg`：仅界面分发包。
- `ClaudeSwitcher-<版本>-installer-kit.zip`：包含安装器、核心、守护进程和界面源码的安装包。

打包过程会启用 Swift 警告作为错误、生成图标、写入 Info.plist 并尝试 ad-hoc 签名；不执行安装器。产物只含本机架构，未做 Developer ID 签名或公证。

需要包含通知中心小组件时，在打包前同时设置真实 `WIDGET_SIGN_IDENTITY` 与 `WIDGET_APP_GROUP`，脚本会在生成 ZIP／DMG 前完成扩展嵌入和同团队签名。详见 [macOS 小组件指南](MACOS-WIDGET.md)。

正式 App 默认调用 `~/.local/bin/claude-switch.sh`，启动后会执行真实环境审计。日常界面开发使用上述隔离入口。完整安装需要 Claude 桌面版、可用代理/TUN、非 CN 出口，以及管理员授权来设置守护进程、时区和 IPv6；按仓库 AGENTS.md，维护者本机安装、更新和部署需要当次明确授权。

## 代码入口与验证

| 路径 | 职责 |
| --- | --- |
| `app/main.swift` | SwiftUI 界面、菜单栏、模型与核心命令调用 |
| `app/StatusWidget.swift` | WidgetKit 只读脱敏摘要与时间线 |
| `core/claude-switch.sh` | 14 项审计、账号快照切换、修复、设置、更新与诊断 |
| `core/stun-probe.py` | WebRTC/STUN 探测 |
| `daemons/` | root 保镖、时区看门狗、用户态自动更新模板 |
| `installer/安装.command` | 正式安装和系统配置 |
| `scripts/package-macos.sh` | 正式 App 和安装包构建 |
| `scripts/build-macos-widget.sh` | 小组件编译、团队签名及嵌入 |
| `tests/MenuBarFixture.swift` | 隔离演示应用入口 |
| `tests/MenuBarModelTests.swift` | Swift 模型隔离回归 |

`test` 等价于 `python3 -B -m unittest discover -s tests -v`。回归使用假脚本和隔离目录；现有套件也包含其他平台源码的静态检查，无需安装 Windows/Linux 环境。详细菜单栏手工验收见 [MENU-BAR-TESTING.md](../tests/MENU-BAR-TESTING.md)。

`build/` 与 `_trash/` 均已被 Git 忽略。修改 `core/`、`daemons/` 或 `installer/` 后，提交前还必须运行 `bash scripts/gen-sums.sh`，并提交更新后的 `SHA256SUMS`。

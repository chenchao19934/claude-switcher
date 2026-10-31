# macOS 菜单栏隔离验证

要求：macOS 13+、Swift 编译器、可用的图形登录会话。模型测试不需要真实 Claude、代理或管理员权限：

```bash
python3 -m unittest discover -s tests -v
```

菜单栏场景覆盖多账号状态解析、A–D 切换与首次使用提示、旧版状态回退、本地账号刷新、切换前重新审计、警告放行、失败/缺行/重复行/空值/超时/非零退出阻断、忙碌互斥、退出保护、隐藏回调、NSPanel 生命周期、菜单重检、快捷键偏好、后台巡检周期配置、自动状态同步、Widget URL 与脱敏摘要。非 macOS 系统跳过这部分，继续运行现有的核心脚本测试。另有 Widget 模型与时间线场景。

## UI 演示程序

`MenuBarFixture.swift` 与生产应用共用 `SwitcherMenu`、`AppDelegate` 和 `QuickPanelView`，仅把核心脚本注入为明确指定的假脚本。未提供脚本路径时拒绝启动；不会回退到 `~/.local/bin/claude-switch.sh`。

演示程序额外提供「菜单内容预览」辅助操作入口和「演示外观」菜单。辅助菜单用于自动化工具呼出面板，不代表已验证原生状态栏右键菜单布局。启动时会输出原生状态栏按钮数量、模板图像属性和辅助功能名称，供检查图标驻留与可访问性。辅助功能属性检查不等于完整的 VoiceOver 语音验收。假核心同目录必须有 `macos-dev-updater.sh`，且显式注入为更新后端；模拟更新停在准备阶段，不执行安装或真正重启。

推荐入口：`bash scripts/dev-macos.sh run --hotkey`。它构建独立演示 App，使用仓库假核心；快捷键偏好仅存内存，退出时释放注册，不写正式用户偏好或 Widget 共享容器。省略 `--hotkey` 不注册全局组合。以下仍保留手工编译示例。

在仓库根目录操作，所有输出放在被忽略的 `_trash/`：

```bash
mkdir -p _trash/menu-bar-demo
swiftc -O -parse-as-library -D CLAUDE_SWITCHER_TESTS \
  -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path _trash/menu-bar-demo/module-cache \
  app/main.swift tests/MenuBarFixture.swift \
  -o _trash/menu-bar-demo/MenuBarFixture \
  -framework SwiftUI -framework AppKit

cat > _trash/menu-bar-demo/fake-core.sh <<'SH'
#!/bin/bash
case "$1" in
  monitor-status) printf 'monitor-version=1\n代理内核=ok\nTUN网卡=ok\n' ;;
  checkdetail)
    for key in 代理内核 TUN网卡 出口IP IP一致 时区 地区 IPv6 DNS WebRTC 保镖 规则置顶 客户端语言 ASN属性 生态可达性; do
      if [ "$key" = ASN属性 ]; then echo "$key=warn:演示机房"; else echo "$key=ok:演示数据"; fi
    done ;;
  status) echo 'current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C accA=1.2G@2026-10-20 accB=900M@2026-10-19 accC=2.0G@2026-10-18' ;;
  switch) echo "OK:演示切换至 $2" ;;
  fix) echo 'FIX:演示修复' ;;
  fingerprint) echo 'GPU=ok:演示设备' ;;
  *) exit 2 ;;
esac
SH
cp tests/fixtures/macos-dev-updater.sh _trash/menu-bar-demo/macos-dev-updater.sh

_trash/menu-bar-demo/MenuBarFixture "$PWD/_trash/menu-bar-demo/fake-core.sh"
# 深色外观（只改变演示应用自身）：
# _trash/menu-bar-demo/MenuBarFixture "$PWD/_trash/menu-bar-demo/fake-core.sh" --dark
```

手动验收：

1. 首次启动显示窗口，顶部有盾牌图标，Dock 没有该应用图标。
2. 点击菜单栏或默认 ⌃⌥Space 切换面板显隐；Esc 收起，空闲失焦收起，再次呼出复用同一 NSPanel。
3. 菜单栏和面板的账号、警告状态一致；右键菜单的「重新检查」必须执行完整审计。检查详情、设置、代理客户端、体检、更新和 AI 配置均在面板内切页。
4. 模拟切换成功后约 2.2 秒隐藏窗口，菜单仍可恢复窗口；失败时保持错误信息。
5. 修复/切换期间重复操作被禁用，菜单和系统的退出请求均被阻止；完成后可以退出。
6. 在「检查设置 → 快捷呼出」录制含 Control/Option/Command 的组合，验证新组合呼出、旧组合释放、冲突保留旧组合、恢复默认与停用；Esc 取消录制，Delete 停用。正式应用偏好持久化由隔离 suite 模型回归验证。
7. 在浅色、深色下检查菜单图标和文字；可在 VoiceOver 中确认图标、菜单项和禁用状态可读取。
8. 选择「退出 Claude 切换器」后图标消失；确认本机已安装的应用和系统服务没有被修改。
9. 导出诊断时，系统保存对话框与结果提示不会导致面板意外收起；含跳过的摘要与检查行保持灰色，不计作通过。
10. 通知中心 Widget 的正式签名、共享容器、系统注册及点击验收按 [MACOS-WIDGET.md](../docs/MACOS-WIDGET.md) 单独执行；编译和模型回归不能替代该项。
11. 用假核心模拟 TUN 或内核掉线：面板隐藏时菜单栏也应自动显示失败，再次呼出时详情一致；模拟恢复后必须重新完整审计，审计失败不能显示通过。模拟监测超时、无效输出、操作繁忙与唤醒补查，确认没有重叠采样或旧结果覆盖新操作。测试不得关闭真实 TUN 或启动真实 Claude。
12. 在「版本更新」检查模拟版本，确认后端只收到 `check`；取消确认不得触发准备更新。确认模拟更新后应显示演示提示，面板恢复可操作；用模型测试覆盖准备失败、错误协议、重启握手和保镖应用互斥。真实已安装 App 的更新与回滚只能在用户明确授权后验收。

App 的轻量采样目标周期固定为 10 秒，不受保镖的 2–10 秒配置影响；它不定时执行完整网络审计。小组件只请求系统刷新，不以菜单栏更新速度作为 WidgetKit 的实时保证。

截图只使用这个演示程序。不要运行真实账号切换或把住宅/代理 IP、凭据放进截图。

以下为隔离演示的主窗口截图，不是顶部状态栏下拉菜单截图。截图拍摄于双账号版本，A–D 四宫格卡片以当前构建为准：

| 浅色系统控件 | 深色系统控件 |
| --- | --- |
| ![浅色演示窗口](../docs/images/macos-menu-bar-demo.jpg) | ![深色演示窗口](../docs/images/macos-menu-bar-demo-dark.jpg) |

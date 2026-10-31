import SwiftUI
import AppKit

// 仅供隔离 UI 验证。没有路径参数就拒绝启动，绝不回退到真实安装的核心脚本。
final class FixtureDelegate: AppDelegate {
    override init() {
        guard CommandLine.arguments.count >= 2,
              FileManager.default.fileExists(atPath: CommandLine.arguments[1]) else {
            fatalError("隔离演示需要显式传入 fake-core.sh 路径")
        }
        let fakeCore = URL(fileURLWithPath: CommandLine.arguments[1])
        let fakeUpdater = fakeCore.deletingLastPathComponent().appendingPathComponent("macos-dev-updater.sh")
        guard FileManager.default.isReadableFile(atPath: fakeUpdater.path) else {
            fatalError("隔离演示需要与假核心位于同目录的 macos-dev-updater.sh；不会回退到真实更新组件")
        }
        super.init(vm: VM(core: fakeCore.path, updateCommand: ["/bin/bash", fakeUpdater.path]),
                   enableSystemIntegration: CommandLine.arguments.contains("--hotkey"),
                   guardSettings: .demo(core: CommandLine.arguments[1]))
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        super.applicationDidFinishLaunching(notification)
        mainWindow?.title = "Claude 切换器 · 隔离演示"
        print("DEMO activation policy: \(NSApplication.shared.activationPolicy().rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let buttons = NSApplication.shared.windows.flatMap { window in
                Self.statusButtons(in: window.contentView)
            }
            print("DEMO native status buttons: \(buttons.count)")
            for button in buttons {
                print("DEMO status icon template: \(button.image?.isTemplate == true)")
                print("DEMO status label: \(button.accessibilityLabel() ?? "")")
                print("DEMO status title: \(button.accessibilityTitle() ?? "")")
                print("DEMO status help: \(button.accessibilityHelp() ?? "")")
                print("DEMO image description: \(button.image?.accessibilityDescription ?? "")")
            }
            fflush(stdout)
        }
        if let window = mainWindow {
            print("DEMO window frame: \(window.frame), visible screen: \(window.screen?.visibleFrame ?? .zero)")
        }
    }

    override func togglePanel() {
        super.togglePanel()
        print("DEMO toggle panel visible: \(mainWindow?.isVisible == true)")
        fflush(stdout)
    }

    override func hidePanel() {
        super.hidePanel()
        print("DEMO hide panel visible: \(mainWindow?.isVisible == true)")
        fflush(stdout)
    }

    private static func statusButtons(in view: NSView?) -> [NSStatusBarButton] {
        guard let view = view else { return [] }
        return (view as? NSStatusBarButton).map { [$0] } ?? view.subviews.flatMap { statusButtons(in: $0) }
    }
}

@main
struct MenuBarFixture: App {
    @NSApplicationDelegateAdaptor(FixtureDelegate.self) var appDelegate

    var body: some Scene {
        SwitcherMenu(vm: appDelegate.vm, controller: appDelegate)
            .commands {
                // 隔离演示的辅助操作入口；原生菜单栏右键菜单另由 AppDelegate 管理。
                CommandMenu("菜单内容预览") {
                    MenuBarContent(vm: appDelegate.vm, showWindow: appDelegate.showMainWindow,
                                   canOperate: { !appDelegate.guardSettings.isApplying })
                }
                CommandMenu("演示外观") {
                    Button("浅色") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
                    Button("深色") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
                }
            }
    }
}

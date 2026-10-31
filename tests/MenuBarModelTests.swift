import Foundation
import AppKit
import Carbon

private let auditKeys = ["代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性"]

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func spin(until condition: () -> Bool, timeout: TimeInterval = 6) throws {
    let limit = Date().addingTimeInterval(timeout)
    while !condition(), Date() < limit {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(condition(), "等待异步结果超时")
}

private func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private func guardStatusJSON(_ interval: Int = 10, throttle: Int? = nil,
                             registered: Bool = true, active: Int? = nil,
                             unknownRuntime: Bool = false) -> String {
    let runtime = unknownRuntime ? "null" : String(active ?? interval)
    return "{\"interval\":\(interval),\"throttleInterval\":\(throttle ?? interval),\"registered\":\(registered),\"activeInterval\":\(runtime)}"
}

private final class GuardBackendFixture {
    var readResult = BodyguardCommandResult(output: guardStatusJSON(), succeeded: true)
    var writeResult: BodyguardCommandResult?
    var readDelay: TimeInterval = 0
    var writeDelay: TimeInterval = 0
    private let lock = NSLock()
    private var readCounter = 0
    private var requestedIntervals: [Int] = []

    var reads: Int {
        lock.lock(); defer { lock.unlock() }
        return readCounter
    }

    var writes: [Int] {
        lock.lock(); defer { lock.unlock() }
        return requestedIntervals
    }

    func model() -> BodyguardSettings {
        BodyguardSettings(readStatus: { [self] in
            lock.lock(); readCounter += 1; lock.unlock()
            Thread.sleep(forTimeInterval: readDelay)
            return readResult
        }, writeInterval: { [self] interval in
            lock.lock(); requestedIntervals.append(interval); lock.unlock()
            Thread.sleep(forTimeInterval: writeDelay)
            return writeResult ?? BodyguardCommandResult(output: guardStatusJSON(interval), succeeded: true)
        })
    }
}

private final class Fixture {
    let root: URL
    let core: URL

    init() throws {
        let trash = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("_trash")
        root = trash.appendingPathComponent("menu-bar-model-\(UUID().uuidString)")
        core = root.appendingPathComponent("fake-core.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("audit", auditKeys.map { "\($0)=ok" }.joined(separator: "\n") + "\n")
        try write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=ok\n")
        try write("status", "current=A hasA=1 hasB=0\n")
        try write("switch-output", "OK:已切换到账号 B\n")
        try write("core-script", """
        #!/bin/bash
        root="$(cd "$(dirname "$0")" && pwd)"
        printf '%s\\n' "$*" >> "$root/calls"
        delay() { if [ -f "$root/$1-delay" ]; then /bin/sleep "$(cat "$root/$1-delay")"; fi; }
        result() { if [ -f "$root/$1-exit" ]; then exit "$(cat "$root/$1-exit")"; fi; }
        case "$1" in
          checkdetail) delay check; cat "$root/audit"; result check ;;
          monitor-status) cat "$root/monitor"; delay monitor; result monitor ;;
          status) cat "$root/status"; result status ;;
          get-client) echo 'client=clash-verge' ;;
          get-check-config) delay get-config; cat "$root/check-config"; result get-config ;;
          set-check-config) printf '%s\n' "$2" > "$root/saved-config"; result set-config ;;
          switch) delay switch; cat "$root/switch-output"; result switch ;;
          fix) delay fix; echo 'FIX:演示修复完成'; result fix ;;
          fingerprint) delay fingerprint; echo 'GPU=ok:演示设备' ;;
          *) exit 2 ;;
        esac
        """)
        try FileManager.default.moveItem(at: root.appendingPathComponent("core-script"), to: core)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func audit(_ changes: [String: String] = [:]) throws {
        try write("audit", auditKeys.map { "\($0)=\(changes[$0] ?? "ok")" }.joined(separator: "\n") + "\n")
    }

    func vm(checkTimeout: TimeInterval = 2, operationTimeout: TimeInterval = 2,
            monitorInterval: TimeInterval? = nil, monitorTimeout: TimeInterval = 1) -> VM {
        VM(core: core.path, checkTimeout: checkTimeout, operationTimeout: operationTimeout,
           monitorInterval: monitorInterval, monitorTimeout: monitorTimeout)
    }

    var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func idle(_ vm: VM) throws { try spin { !vm.isBusy } }

    func poll(_ vm: VM) throws {
        vm.pollEnvironment()
        try spin { !vm.monitorInFlight && !vm.isBusy }
    }

    func deniedSwitch(_ vm: VM) throws {
        vm.switchTo("B")
        try idle(vm)
        try expect(vm.phase == .failed, "审计异常应阻断切换")
        try expect(!calls.contains { $0.hasPrefix("switch ") }, "审计异常仍执行了 switch")
        try expect(vm.canQuit, "失败后应该可以退出")
    }
}

@main
struct MenuBarModelTests {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw TestFailure(description: "缺少测试场景") }
            let name = CommandLine.arguments[1]
            let f = try Fixture()
            switch name {
            case "startup_once":
                let vm = f.vm()
                vm.start(); vm.start()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status"], "启动不应重复检查")
                try expect(vm.phase == .ready && vm.lastCheckSummary == "通过" && vm.current == "A", "初始状态不一致")
            case "multi_account_status":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C accA=1.2G@2026-10-20 accB=900M@2026-10-19 accC=2.0G@2026-10-18\n")
                try f.write("switch-output", "OK:已切换到账号 C\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.archived == Set(["A", "B", "C"]), "应解析三个已建档账号")
                try expect(vm.stamps["A"] == AccountStamp(size: "1.2G", date: "2026-10-20"), "应解析账号大小与日期")
                let card = ContentView(vm: vm)
                try expect(card.accountSubtitle("A") == "当前", "当前账号副标题不正确")
                try expect(card.accountSubtitle("B") == "已建档 · 900M · 10-19", "已建档副标题应带大小与日期")
                try expect(card.accountSubtitle("D") == "未初始化", "空槽位副标题不正确")
                vm.switchTo("C"); try f.idle(vm)
                try expect(vm.current == "C" && vm.note.isEmpty, "已建档的 C 不应提示首次登录")
                try expect(f.calls.contains("switch C"), "C 应被允许切换")
            case "first_use_cd_note":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C\n")
                try f.write("switch-output", "OK:已切换到账号 D\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                vm.switchTo("D"); try f.idle(vm)
                try expect(vm.current == "D", "D 应被允许切换")
                try expect(vm.note.contains("D 号首次使用") && vm.note.contains("登录"), "D 首次使用应提示登录")
            case "legacy_status_fallback":
                try f.write("status", "current=B hasA=1 hasB=1\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.current == "B" && vm.archived == Set(["A", "B"]), "旧版 status 应回退为 A/B")
            case "invalid_multi_account_status":
                try f.write("status", "current=A hasA=1 hasB=0 hasC=0 hasD=0 accounts=A,E\n")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "非法账号列表不可进入界面")
            case "warnings_allowed":
                try f.audit(["ASN属性": "warn:演示机房"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.lastCheckSummary == "有警告" && vm.current == "B", "警告应展示并允许切换")
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"], "切换前必须先完整审计")
            case "skipped_optional_allowed":
                try f.audit(["DNS": "skip:用户已禁用", "WebRTC": "skip:用户已禁用"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.phase == .done && vm.current == "B", "显式跳过的非关键项不应阻断切换")
                try expect(vm.rows.first { $0.name == "DNS 走隧道" }?.state == .skip, "跳过项必须显示 skip")
            case "settings_round_trip":
                try f.write("check-config", #"{"disabled":["DNS"],"allowOptionalFailures":true,"logging":false}"#)
                let vm = f.vm()
                vm.loadCheckConfig()
                try spin { !vm.settingsBusy }
                try expect(vm.disabledChecks == Set(["DNS"]), "应读取已禁用的 DNS 检查")
                try expect(vm.allowOptionalFailures && !vm.loggingEnabled, "应读取非关键失败与日志设置")
                vm.disabledChecks.insert("WebRTC")
                vm.saveCheckConfig()
                try spin { !vm.settingsBusy }
                try f.idle(vm)
                let saved = try String(contentsOf: f.root.appendingPathComponent("saved-config"), encoding: .utf8)
                guard let data = saved.data(using: .utf8) else { throw TestFailure(description: "配置不是有效 UTF-8") }
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let disabled = config?["disabled"] as? [String]
                try expect(Set(disabled ?? []) == Set(["DNS", "WebRTC"]), "保存必须保留已有禁用项并加入 WebRTC")
                try expect(config?["allowOptionalFailures"] as? Bool == true, "保存必须保留非关键失败设置")
                try expect(config?["logging"] as? Bool == false, "保存必须保留日志开关")
                try expect(f.calls.contains("checkdetail"), "保存成功后必须重新检查")
            case "local_status_refresh":
                let vm = f.vm()
                vm.refreshAccountStatus()
                try expect(f.calls.isEmpty, "菜单提前出现时不可抢占启动审计")
                vm.start(); try f.idle(vm)
                try f.write("status", "current=B hasA=1 hasB=1\n")
                vm.refreshAccountStatus(); try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status", "status"], "展开菜单只应读取本地状态")
                try expect(vm.current == "B" && vm.lastCheckSummary == "通过", "账号更新不应改变上次审计结果")
            case "fresh_audit":
                let vm = f.vm()
                vm.refresh(); try f.idle(vm)
                try f.audit(["TUN网卡": "fail:已断开"])
                try f.deniedSwitch(vm)
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 2, "不可复用上次通过结果")
            case "failed_check":
                try f.audit(["WebRTC": "fail:演示失败"])
                try f.deniedSwitch(f.vm())
            case "incomplete_check":
                try f.write("audit", auditKeys.dropLast().map { "\($0)=ok" }.joined(separator: "\n"))
                try f.deniedSwitch(f.vm())
            case "duplicate_check":
                try f.write("audit", auditKeys.dropLast().map { "\($0)=ok" }.joined(separator: "\n") + "\n代理内核=ok\n")
                try f.deniedSwitch(f.vm())
            case "duplicate_overwrite":
                try f.audit(["TUN网卡": "fail:断开"])
                let s = try String(contentsOf: f.root.appendingPathComponent("audit"), encoding: .utf8)
                try f.write("audit", s + "TUN网卡=ok\n")
                try f.deniedSwitch(f.vm())
            case "empty_check":
                try f.write("audit", "")
                try f.deniedSwitch(f.vm())
            case "unknown_check_code":
                try f.audit(["TUN网卡": "unknown"])
                try f.deniedSwitch(f.vm())
            case "empty_check_code":
                try f.audit(["TUN网卡": ""])
                try f.deniedSwitch(f.vm())
            case "nonzero_check":
                try f.write("check-exit", "7")
                try f.deniedSwitch(f.vm())
            case "timeout_check":
                try f.write("check-delay", "3")
                let vm = f.vm(checkTimeout: 0.1)
                try f.deniedSwitch(vm)
                try expect(vm.lastCheckSummary == "失败" && vm.banner.contains("超时"), "超时不可展示通过")
            case "invalid_status":
                try f.write("status", "current=B hasB=1")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "账号读取失败不可沿用旧状态")
                try expect(vm.lastCheckSummary == "失败", "账号读取失败时菜单不可显示通过")
            case "nonzero_status":
                try f.write("status-exit", "1")
                try f.deniedSwitch(f.vm())
            case "switch_note_then_failure":
                try f.write("switch-output", "NOTE:开始切换\nFAIL:模拟归档失败\n")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "NOTE 后的 FAIL 不可当作成功")
            case "empty_switch":
                try f.write("switch-output", "")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "空切换结果不可当作成功")
            case "nonzero_switch":
                try f.write("switch-exit", "4")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "非零退出即使打印 OK 也不可当作成功")
            case "timeout_switch":
                try f.write("switch-delay", "3")
                let vm = f.vm(operationTimeout: 0.1)
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A" && vm.canQuit, "切换超时应恢复可操作状态")
            case "busy_guard":
                try f.write("switch-delay", "0.2")
                let vm = f.vm()
                vm.switchTo("B")
                try expect(!vm.canQuit, "切换请求开始后不可退出")
                vm.switchTo("A"); vm.refresh(); vm.fixAll(); vm.inspectFingerprint()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"], "忙碌时应忽略重复操作")
                try expect(vm.canQuit && vm.current == "B", "切换完成后应允许退出")
            case "fix_guard":
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                vm.fixAll()
                try expect(!vm.canQuit, "修复期间不可退出")
                vm.refresh(); vm.switchTo("B"); vm.fixAll()
                try f.idle(vm)
                try expect(f.calls == ["fix", "checkdetail", "get-client", "status"], "修复结束必须重新检查，不能并行执行")
                try expect(vm.canQuit && vm.phase == .ready, "修复后应该可以退出")
            case "failed_fix":
                try f.write("fix-exit", "1")
                let vm = f.vm()
                vm.fixAll(); try f.idle(vm)
                try expect(vm.phase == .failed && vm.canQuit && f.calls == ["fix"], "修复失败不可被后续状态覆盖")
            case "checking_allows_quit":
                try f.write("check-delay", "0.2")
                let vm = f.vm()
                vm.refresh()
                try expect(vm.canQuit, "普通检查期间应允许退出")
                try f.idle(vm)
            case "hide_after_success":
                let vm = f.vm()
                var hidden = false
                vm.onSwitchCompleted = { hidden = true }
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .done && !hidden, "成功提示应该短暂保留")
                try spin(until: { hidden })
                try expect(vm.phase == .ready && vm.current == "B", "成功后应恢复就绪，不应退出进程")
            case "reopen_cancels_hide":
                let vm = f.vm()
                var hidden = false
                vm.onSwitchCompleted = { hidden = true }
                vm.switchTo("B"); try f.idle(vm)
                vm.prepareToShow()
                pump(2.4)
                try expect(!hidden && vm.phase == .ready, "主动重开窗口后不能被旧回调隐藏")
            case "window_lifecycle":
                let vm = f.vm()
                let app = NSApplication.shared
                let delegate = AppDelegate(vm: vm)
                app.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                let first = delegate.mainWindow
                try expect(first?.isVisible == true, "首次启动应该显示窗口")
                try expect(first is NSPanel, "快捷呼出应该使用 NSPanel")
                try expect(first?.styleMask.contains(.nonactivatingPanel) == true, "快捷面板应支持非激活呼出")
                try expect(first?.styleMask.contains(.miniaturizable) == false, "快捷面板不应提供最小化")
                try expect(first?.isReleasedWhenClosed == false, "收起后必须保留同一面板")
                try expect(first?.level == .floating, "快捷面板应浮于普通窗口")
                try expect(delegate.windowShouldClose(first!) == false, "关闭应由控制器转为隐藏")
                try expect(first?.isVisible == false, "关窗应该隐藏")
                try expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "关窗不应退出")
                delegate.showMainWindow()
                try expect(delegate.mainWindow === first && first?.isVisible == true, "重开应该复用同一窗口")
                first?.orderOut(nil)
            case "panel_toggle_no_audit":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.togglePanel()
                let first = delegate.mainWindow
                try expect(first?.isVisible == true, "首次 toggle 应呼出面板")
                delegate.togglePanel()
                try expect(first?.isVisible == false, "第二次 toggle 应收起面板")
                delegate.togglePanel()
                try expect(first?.isVisible == true && delegate.mainWindow === first, "第三次 toggle 应复用原面板")
                try expect(f.calls.isEmpty, "呼出和收起不能触发额外安检或账号操作")
                try expect(delegate.statusItem == nil, "隔离控制器不得自动创建系统集成")
                delegate.hidePanel()
            case "panel_menu_recheck":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                NSApplication.shared.setActivationPolicy(.accessory)
                vm.start()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status"], "应先完成一次启动审计")
                delegate.recheckFromMenu()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status", "checkdetail", "get-client", "status"], "菜单重新检查必须新增完整审计，不能被呼出时的本地状态读取吞掉")
                try expect(vm.phase == .ready && delegate.mainWindow?.isVisible == true, "菜单重检应呼出面板并完成检查")
                delegate.hidePanel()
            case "panel_idle_deactivation":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                try expect(delegate.canAutoDismiss, "空闲面板应该允许失焦收起")
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == false, "空闲失焦应收起面板")
                try expect(f.calls.isEmpty && vm.canQuit, "失焦不应执行核心命令或改变退出许可")
            case "panel_busy_deactivation":
                try f.write("check-delay", "0.2")
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                vm.refresh()
                try expect(vm.isBusy && !delegate.canAutoDismiss, "审计期间不得自动收起")
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == true, "审计失焦必须保留进度")
                try f.idle(vm)
                vm.fixAll()
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == true && !delegate.canAutoDismiss, "修复失焦必须保留面板")
                try f.idle(vm)
                vm.switchTo("B")
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == true && !delegate.canAutoDismiss, "切换前审计失焦必须保留面板")
                try f.idle(vm)
                try expect(vm.current == "B", "失焦不能取消正在进行的切换")
                delegate.hidePanel()
            case "panel_settings_recording_guard":
                try f.write("check-config", #"{"disabled":[],"allowOptionalFailures":false,"logging":true}"#)
                try f.write("get-config-delay", "0.2")
                let vm = f.vm()
                let preferences = AppPreferences()
                let delegate = AppDelegate(vm: vm, preferences: preferences)
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                vm.loadCheckConfig()
                try expect(vm.settingsBusy && !vm.isBusy && !delegate.canAutoDismiss, "设置读取需要独立失焦保护")
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == true, "设置读取中不能自动收起")
                try spin { !vm.settingsBusy }
                preferences.isRecordingShortcut = true
                try expect(!delegate.canAutoDismiss, "录制快捷键期间不能自动收起")
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == true, "录制失焦应保留面板")
                preferences.isRecordingShortcut = false
                try expect(delegate.canAutoDismiss, "设置读取与录制结束应解除保护")
                delegate.dismissOnDeactivation()
                try expect(delegate.mainWindow?.isVisible == false, "保护解除后失焦应收起")
            case "panel_child_sheet_guard":
                let delegate = AppDelegate(vm: f.vm())
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                let parent = delegate.mainWindow!
                let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80), styleMask: .titled, backing: .buffered, defer: false)
                parent.addChildWindow(child, ordered: .above)
                child.orderFront(nil)
                try expect(child.isVisible && !delegate.canAutoDismiss, "可见子窗口必须保护主面板")
                delegate.dismissOnDeactivation()
                try expect(parent.isVisible, "子窗口临时取焦不能收起主面板")
                parent.removeChildWindow(child)
                child.orderOut(nil)
                let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80), styleMask: .titled, backing: .buffered, defer: false)
                parent.beginSheet(sheet)
                try expect(parent.attachedSheet === sheet && !delegate.canAutoDismiss, "附加 sheet 必须保护主面板")
                delegate.dismissOnDeactivation()
                try expect(parent.isVisible, "sheet 临时取焦不能收起主面板")
                parent.endSheet(sheet)
                sheet.orderOut(nil)
                try spin { parent.attachedSheet == nil }
                try expect(delegate.canAutoDismiss, "子窗口与 sheet 关闭后应恢复自动收起")
                delegate.hidePanel()
            case "panel_busy_close":
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                vm.fixAll()
                try expect(delegate.windowShouldClose(delegate.mainWindow!) == false, "繁忙关闭仍应转为收起")
                try expect(delegate.mainWindow?.isVisible == false && vm.isBusy, "收起不得取消后台修复")
                try expect(delegate.applicationShouldTerminate(app) == .terminateCancel, "收起后仍必须阻止退出修复进程")
                try expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "收起最后一个窗口不应退出")
                delegate.showMainWindow()
                try expect(delegate.mainWindow?.isVisible == true && vm.isBusy, "重开应保留繁忙进度")
                try f.idle(vm)
                try expect(f.calls == ["fix", "checkdetail", "get-client", "status"], "繁忙关闭和重开不得重复修复或审计")
                delegate.hidePanel()
            case "panel_url_open_only":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                for text in ["https://panel", "claude-switcher://switch/B", "claude-switcher://panel?account=B", "claude-switcher://panel/other"] {
                    delegate.application(app, open: [URL(string: text)!])
                    try expect(delegate.mainWindow == nil, "不支持的 URL 不应创建面板")
                }
                delegate.application(app, open: [URL(string: "claude-switcher://panel")!])
                try expect(delegate.mainWindow?.isVisible == true, "Widget URL 应呼出面板")
                try expect(f.calls.isEmpty && vm.current == "?", "Widget URL 不能触发安检、换号或启动 Claude")
                delegate.hidePanel()
            case "shortcut_preferences":
                let suite = "claude-switcher.tests.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "无法创建隔离偏好") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let preferences = AppPreferences(defaults: defaults)
                let delegate = AppDelegate(vm: f.vm(), preferences: preferences)
                try expect(preferences.shortcut == .standard && GlobalShortcut.standard.isValid, "首次启动应有有效默认快捷键")
                try expect(GlobalShortcut.standard.label == "⌃⌥Space", "默认快捷键文案不正确")
                let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | shiftKey))
                delegate.setShortcut(custom)
                try expect(preferences.shortcut == custom && custom.label == "⌃⌥⇧K", "应保存自定义快捷键及文案")
                try expect(AppPreferences(defaults: defaults).shortcut == custom, "重载应保留自定义快捷键")
                delegate.setShortcut(nil)
                try expect(preferences.shortcut == nil && AppPreferences(defaults: defaults).shortcut == nil, "停用必须持久化，不能重载后自动恢复")
                delegate.setShortcut(.standard)
                try expect(AppPreferences(defaults: defaults).shortcut == .standard, "恢复默认必须持久化")
                try expect(f.calls.isEmpty, "修改快捷键不得执行核心命令")
            case "shortcut_invalid_rejected":
                let suite = "claude-switcher.tests.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "无法创建隔离偏好") }
                defer { defaults.removePersistentDomain(forName: suite) }
                let preferences = AppPreferences(defaults: defaults)
                let delegate = AppDelegate(vm: f.vm(), preferences: preferences)
                let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
                delegate.setShortcut(custom)
                for invalid in [GlobalShortcut(keyCode: 0, modifiers: 0), GlobalShortcut(keyCode: 0, modifiers: UInt32(shiftKey)), GlobalShortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey)), GlobalShortcut(keyCode: 127, modifiers: UInt32(cmdKey)), GlobalShortcut(keyCode: 0, modifiers: UInt32.max)] {
                    try expect(!invalid.isValid, "非法组合不应被标记为有效")
                    delegate.setShortcut(invalid)
                    try expect(preferences.shortcut == custom, "无系统集成模式也必须拒绝非法组合并保留原设置")
                    try expect(AppPreferences(defaults: defaults).shortcut == custom, "非法组合不得覆盖已保存快捷键")
                    try expect(!preferences.shortcutMessage.isEmpty, "拒绝非法组合应提供原因")
                }
                defaults.set(try JSONEncoder().encode(GlobalShortcut(keyCode: 0, modifiers: 0)), forKey: "quickPanel.shortcut")
                try expect(AppPreferences(defaults: defaults).shortcut == .standard, "落盘组合无效时应安全回退默认")
            case "shortcut_press_gate":
                var gate = ShortcutPressGate()
                try expect(gate.accepts(timestamp: 100), "首次快捷键应被接受")
                try expect(!gate.accepts(timestamp: 100), "同一按键经 Carbon 与本地路径到达时只能接受一次")
                try expect(!gate.accepts(timestamp: 100.01) && !gate.accepts(timestamp: 100.149), "来源时间轻微漂移不能造成双重 toggle")
                try expect(gate.accepts(timestamp: 100.2), "正常后续按键应可继续呼出")
                try expect(!gate.accepts(timestamp: 101, isRepeat: true), "长按自动重复不能切换面板")
                try expect(gate.accepts(timestamp: 101), "被拒绝的自动重复不能阻止后续真实按键")
                for invalid in [-1.0, Double.infinity, -Double.infinity, Double.nan] {
                    try expect(!gate.accepts(timestamp: invalid), "非法时间不得改变快捷键状态")
                }
                try expect(!gate.accepts(timestamp: 100.5), "迟到的旧事件不得再次切换")
                try expect(gate.accepts(timestamp: 101.2), "旧事件与非法时间不应破坏后续正常事件")
            case "panel_shortcut_protection":
                let preferences = AppPreferences()
                let delegate = AppDelegate(vm: f.vm(), preferences: preferences)
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                let parent = delegate.mainWindow!
                preferences.isRecordingShortcut = true
                delegate.handleShortcutPress(timestamp: 100)
                try expect(parent.isVisible, "录制中的快捷键不能收起面板")
                preferences.isRecordingShortcut = false
                let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80), styleMask: .titled, backing: .buffered, defer: false)
                parent.addChildWindow(child, ordered: .above)
                child.orderFront(nil)
                delegate.handleShortcutPress(timestamp: 101)
                try expect(parent.isVisible && child.isVisible, "Carbon 与本地统一入口都必须保护可见子窗口")
                parent.removeChildWindow(child)
                child.orderOut(nil)
                let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80), styleMask: .titled, backing: .buffered, defer: false)
                parent.beginSheet(sheet)
                delegate.handleShortcutPress(timestamp: 102)
                try expect(parent.isVisible && parent.attachedSheet === sheet, "附加 sheet 期间快捷键不能隐藏主面板")
                parent.endSheet(sheet)
                sheet.orderOut(nil)
                try spin { parent.attachedSheet == nil }
                delegate.showMainWindow()
                delegate.handleShortcutPress(timestamp: 103)
                try expect(!parent.isVisible, "录制与模态保护结束后快捷键应恢复切换")
                try expect(f.calls.isEmpty, "快捷键保护不能执行核心命令")
            case "panel_shortcut_busy_toggle":
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                NSApplication.shared.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                vm.fixAll()
                delegate.handleShortcutPress(timestamp: 100)
                try expect(delegate.mainWindow?.isVisible == false && vm.isBusy && !vm.canQuit, "手动快捷键可收起繁忙面板，但不得取消修复或解除退出保护")
                delegate.handleShortcutPress(timestamp: 100)
                delegate.handleShortcutPress(timestamp: 100.02)
                try expect(delegate.mainWindow?.isVisible == false, "同一按键的两来源不能把面板重新弹出")
                delegate.handleShortcutPress(timestamp: 100.3)
                try expect(delegate.mainWindow?.isVisible == true && vm.isBusy, "后续真实按键应能重开并保留修复进度")
                try f.idle(vm)
                try expect(f.calls == ["fix", "checkdetail", "get-client", "status"], "手动快捷键收起与重开不能重复或中断修复")
                delegate.hidePanel()
            case "monitor_healthy":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try f.poll(vm); try f.poll(vm)
                try expect(f.calls.filter { $0 == "monitor-status" }.count == 2, "空闲时应完成独立轻量采样")
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 1, "健康采样不能不断重跑14项网络审计")
                try expect(vm.phase == .ready && vm.rows.allSatisfy { $0.state == .ok }, "健康采样不得清空完整检查结果")
            case "monitor_failure_recovery":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=fail\n")
                try f.poll(vm)
                try expect(vm.phase == .failed && vm.lastCheckSummary == "失败", "TUN离线必须立即更新为失败")
                try expect(vm.rows.first { $0.name == "TUN 网卡" }?.state == .fail, "主窗口TUN检查项必须同步失败")
                try expect(vm.rows.first { $0.name == "出口 IP" }?.state == .ok, "轻量采样不得伪造其他检查结果")
                try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 42).menuSummary == "未通过", "菜单栏摘要必须与后台失败一致")
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 1, "离线采样不应阻塞于完整网络审计")
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=ok\n")
                try f.poll(vm)
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 2, "恢复后必须自动重新完成14项检查")
                try expect(vm.phase == .ready && vm.lastCheckSummary == "通过", "恢复且审计通过后应同步主窗口状态")
            case "monitor_recovery_still_failed":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try f.write("monitor", "monitor-version=1\n代理内核=fail\nTUN网卡=fail\n")
                try f.poll(vm)
                try f.audit(["出口IP": "fail:目标国家不一致"])
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=ok\n")
                try f.poll(vm)
                try expect(vm.phase == .failed && vm.lastCheckSummary == "失败", "内核与TUN恢复不能覆盖其他硬性安全失败")
                try expect(vm.rows.first { $0.name == "出口 IP" }?.state == .fail, "恢复审计必须保留出口失败")
                try f.deniedSwitch(vm)
            case "monitor_invalid_responses":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                for output in ["", "monitor-version=1\n代理内核=ok\n",
                               "monitor-version=1\n代理内核=ok\n代理内核=ok\n",
                               "monitor-version=1\n代理内核=ok\nTUN网卡=warn\n",
                               "monitor-version=1\n代理内核=ok\nTUN网卡=skip\n",
                               "monitor-version=2\n代理内核=ok\nTUN网卡=ok\n",
                               "monitor-version=1\n代理内核=ok\nTUN网卡=ok:在线\n",
                               "monitor-version=1\n代理内核=ok\nTUN网卡=ok\n额外项=ok\n",
                               "用法: claude-switch.sh check|checkdetail|status\n"] {
                    try f.write("monitor", output)
                    try f.poll(vm)
                    try expect(vm.phase == .failed && vm.lastCheckSummary == "失败", "无效/旧核心采样输出不得冒充健康")
                    try expect(vm.rows.prefix(2).allSatisfy { $0.state == .fail }, "采样结果未确认时两个监测项均应拒绝通过")
                }
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=ok\n")
                try f.write("monitor-exit", "1")
                try f.poll(vm)
                try expect(vm.phase == .failed, "非零退出码即使带全ok输出也必须拒绝")
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 1, "无效采样不能触发恢复审计")
            case "monitor_timeout":
                let vm = f.vm(monitorTimeout: 0.06)
                vm.start(); try f.idle(vm)
                try f.write("monitor-delay", "0.3")
                try f.poll(vm)
                try expect(vm.phase == .failed && vm.rows.prefix(2).allSatisfy { $0.state == .fail }, "采样超时不得沿用先输出的全ok结果")
                try expect(!vm.isBusy && !vm.monitorInFlight && vm.canQuit, "超时后必须释放采样状态与前台操作能力")
            case "monitor_busy_skip":
                try f.write("check-delay", "0.2")
                let vm = f.vm()
                vm.start(); vm.pollEnvironment()
                try f.idle(vm)
                try expect(!f.calls.contains("monitor-status"), "启动审计中不能并发采样")
                try f.write("fix-delay", "0.2")
                vm.fixAll(); vm.pollEnvironment()
                try f.idle(vm)
                try expect(!f.calls.contains("monitor-status"), "前台修复中不能并发采样")
                try f.write("check-config", #"{"disabled":[],"allowOptionalFailures":false,"logging":true}"#)
                try f.write("get-config-delay", "0.2")
                vm.loadCheckConfig(); vm.pollEnvironment()
                try spin { !vm.settingsBusy }
                try expect(!f.calls.contains("monitor-status"), "检查设置事务中不能并发采样")
                try f.poll(vm)
                try expect(f.calls.filter { $0 == "monitor-status" }.count == 1, "事务结束后采样应恢复")
            case "monitor_no_overlap":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try f.write("monitor-delay", "0.25")
                vm.pollEnvironment(); vm.pollEnvironment(); vm.pollEnvironment()
                try expect(vm.monitorInFlight && !vm.isBusy, "只读采样应独立互斥且不占用前台操作锁")
                try spin { f.calls.contains("monitor-status") }
                vm.pollEnvironment()
                try spin { !vm.monitorInFlight }
                try expect(f.calls.filter { $0 == "monitor-status" }.count == 1, "较慢采样运行期间不得叠加请求")
                try f.poll(vm)
                try expect(f.calls.filter { $0 == "monitor-status" }.count == 2, "完成后才能开始下一轮采样")
            case "monitor_late_sample":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=fail\n")
                try f.write("monitor-delay", "0.45")
                vm.pollEnvironment()
                try spin { f.calls.contains("monitor-status") }
                pump(0.04)
                vm.refresh(); try f.idle(vm)
                try expect(vm.phase == .ready, "采样运行时前台重检应正常完成")
                try spin { !vm.monitorInFlight }
                try expect(vm.phase == .ready && vm.rows.allSatisfy { $0.state == .ok }, "迟到的旧失败不得覆盖前台新审计")
            case "monitor_hidden_timer_and_stop":
                let vm = f.vm(monitorInterval: 0.12)
                let delegate = AppDelegate(vm: vm)
                delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                try f.idle(vm)
                delegate.hidePanel()
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=fail\n")
                try spin { vm.phase == .failed }
                try spin { delegate.statusItem?.button?.title.contains("未通过") == true }
                try expect(delegate.mainWindow?.isVisible == false, "隐窗时后台失败应同步菜单栏且不强制弹窗")
                vm.stopMonitoring()
                let stoppedCount = f.calls.filter { $0 == "monitor-status" }.count
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=ok\n")
                pump(0.4)
                try expect(f.calls.filter { $0 == "monitor-status" }.count == stoppedCount, "停止监测后不能继续派发定时请求")
                try expect(vm.phase == .failed, "停止监测后不能隐式更新检查结果")
            case "monitor_stop_discards_inflight":
                let vm = f.vm(monitorInterval: 10)
                vm.start(); try f.idle(vm)
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=fail\n")
                try f.write("monitor-delay", "0.3")
                vm.pollEnvironment()
                try spin { f.calls.contains("monitor-status") }
                vm.stopMonitoring()
                try spin { !vm.monitorInFlight }
                try expect(vm.phase == .ready && vm.rows.allSatisfy { $0.state == .ok }, "停止后已发出的采样回调也必须丢弃")
            case "monitor_wake":
                let vm = f.vm(monitorInterval: 10)
                vm.start(); try f.idle(vm)
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=fail\n")
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                try spin { vm.phase == .failed }
                vm.stopMonitoring()
                try expect(f.calls.filter { $0 == "monitor-status" }.count == 1, "唤醒后应立即补查，无需等待下一次10秒定时")
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 1, "唤醒轻量检测失败不应重跑完整审计")
            case "monitor_guard_application":
                let backend = GuardBackendFixture()
                backend.writeDelay = 0.2
                let settings = backend.model()
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm, guardSettings: settings)
                settings.refresh(); try spin { !settings.isBusy }
                vm.start(); try f.idle(vm)
                settings.selectedInterval = 5; settings.apply()
                vm.pollEnvironment()
                try expect(settings.isApplying && !vm.monitorInFlight, "管理员应用周期时应跳过采样")
                try spin { !settings.isBusy }
                try expect(!f.calls.contains("monitor-status"), "后台配置事务不得派发核心采样")
                try f.poll(vm)
                try expect(f.calls.filter { $0 == "monitor-status" }.count == 1, "应用完成后应恢复采样")
                try expect(delegate.guardSettings === settings, "采样互斥应使用控制器的同一配置模型")
            case "monitor_guard_late_sample":
                let backend = GuardBackendFixture()
                backend.writeDelay = 0.1
                let settings = backend.model()
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm, guardSettings: settings)
                settings.refresh(); try spin { !settings.isBusy }
                vm.start(); try f.idle(vm)
                try f.write("monitor", "monitor-version=1\n代理内核=ok\nTUN网卡=fail\n")
                try f.write("monitor-delay", "0.45")
                vm.pollEnvironment()
                try spin { f.calls.contains("monitor-status") }
                settings.selectedInterval = 5; settings.apply()
                try spin { !settings.isBusy }
                try expect(settings.current?.verifiedInterval == 5, "后台配置应先完成")
                try spin { !vm.monitorInFlight }
                try expect(vm.phase == .ready, "配置事务开始前发出的迟到采样即使事务已结束也必须丢弃")
                try f.poll(vm)
                try expect(vm.phase == .failed && delegate.guardSettings === settings, "后续新采样应恢复正常生效")
            case "bodyguard_status_validation":
                try expect(BodyguardIntervalStatus.decode(guardStatusJSON())?.verifiedInterval == 10, "一致且已注册的调度才可显示已生效")
                for json in [guardStatusJSON(5, throttle: 10), guardStatusJSON(5, active: 10), guardStatusJSON(5, registered: false), guardStatusJSON(5, unknownRuntime: true)] {
                    guard let status = BodyguardIntervalStatus.decode(json) else { throw TestFailure(description: "合法但未确认的状态应可展示原因") }
                    try expect(status.verifiedInterval == nil, "未知、未注册或不一致的运行状态不得冒充已生效")
                }
                for json in ["not-json", "{}", guardStatusJSON(0), guardStatusJSON(1), guardStatusJSON(11), guardStatusJSON(5, throttle: 0), guardStatusJSON(5, active: 11), String(repeating: " ", count: 4097) + guardStatusJSON()] {
                    try expect(BodyguardIntervalStatus.decode(json) == nil, "无效或过大后台响应必须拒绝")
                }
            case "bodyguard_invalid_interval":
                let backend = GuardBackendFixture()
                let settings = backend.model()
                settings.refresh()
                try spin { !settings.isBusy }
                for interval in [Int.min, -1, 0, 1, 11, Int.max] {
                    settings.selectedInterval = interval
                    try expect(!settings.canApply, "越界整数不能成为可应用配置")
                    settings.apply()
                    try expect(!settings.isBusy && !settings.isApplying && settings.current?.verifiedInterval == 10, "拒绝非法值不得改变已核对周期")
                }
                try expect(backend.writes.isEmpty, "非法输入不得进入管理员写入后端")
                settings.selectedInterval = 2
                try expect(settings.canApply, "最短支持周期应可选择")
                settings.selectedInterval = 10
                try expect(!settings.canApply, "当前已核对周期无需重复应用")
            case "bodyguard_apply_success":
                let backend = GuardBackendFixture()
                backend.writeDelay = 0.1
                let settings = backend.model()
                settings.refresh()
                try spin { !settings.isBusy }
                settings.selectedInterval = 2
                settings.apply()
                try expect(settings.isBusy && settings.isApplying, "应用请求必须立即进入互斥状态")
                settings.selectedInterval = 9
                try spin { !settings.isBusy }
                try expect(settings.current?.verifiedInterval == 2 && settings.selectedInterval == 2, "只有与已发请求匹配的已核对响应才能提交结果")
                try expect(backend.writes == [2] && !settings.canApply, "成功应用不能继续派发相同配置")
                settings.apply()
                try expect(backend.writes == [2], "同周期应用应保持幂等")
                settings.selectedInterval = 10
                settings.apply()
                try spin { !settings.isBusy }
                try expect(settings.current?.verifiedInterval == 10 && backend.writes == [2, 10], "默认周期边界也应可恢复")
            case "bodyguard_cancel_preserves":
                let backend = GuardBackendFixture()
                backend.writeResult = BodyguardCommandResult(output: "", succeeded: false, cancelled: true)
                let settings = backend.model()
                settings.refresh()
                try spin { !settings.isBusy }
                settings.selectedInterval = 5
                settings.apply()
                try spin { !settings.isBusy }
                try expect(settings.current?.verifiedInterval == 10 && !settings.isApplying, "取消管理员授权必须保留已知旧周期并解除互斥")
                try expect(settings.message.contains("取消") && !settings.message.contains("已核对后台调度为 5"), "取消不得展示为应用成功")
                try expect(settings.canApply && backend.writes == [5], "取消后应允许用户主动重试")
            case "bodyguard_apply_unconfirmed":
                let responses = [
                    BodyguardCommandResult(output: guardStatusJSON(5), succeeded: false),
                    BodyguardCommandResult(output: "not-json", succeeded: true),
                    BodyguardCommandResult(output: guardStatusJSON(7), succeeded: true),
                    BodyguardCommandResult(output: guardStatusJSON(5, unknownRuntime: true), succeeded: true),
                    BodyguardCommandResult(output: guardStatusJSON(5, registered: false), succeeded: true),
                    BodyguardCommandResult(output: guardStatusJSON(5, throttle: 10), succeeded: true),
                ]
                for response in responses {
                    let backend = GuardBackendFixture()
                    backend.writeResult = response
                    let settings = backend.model()
                    settings.refresh()
                    try spin { !settings.isBusy }
                    settings.selectedInterval = 5
                    settings.apply()
                    try spin { !settings.isBusy }
                    try expect(settings.current == nil && !settings.canApply && !settings.isApplying, "失败或不匹配响应必须清除未确认状态，不沿用旧绿灯")
                    try expect(settings.message.contains("未确认") && backend.writes == [5], "失败应要求重新读取，不能自动重复写入")
                }
            case "bodyguard_operation_serialization":
                let backend = GuardBackendFixture()
                backend.readDelay = 0.15
                backend.writeDelay = 0.15
                let settings = backend.model()
                settings.refresh()
                settings.refresh()
                settings.selectedInterval = 5
                settings.apply()
                try spin { !settings.isBusy }
                try expect(backend.reads == 1 && backend.writes.isEmpty, "读取中应忽略重复读取和应用")
                settings.selectedInterval = 5
                settings.apply()
                settings.apply()
                settings.refresh()
                try spin { !settings.isBusy }
                try expect(backend.reads == 1 && backend.writes == [5], "应用中不得并发读取或重复写入")
                try expect(settings.current?.verifiedInterval == 5, "重复操作不能覆盖已提交的后台响应")
            case "bodyguard_vm_busy_denies":
                try f.write("check-delay", "0.2")
                try f.write("check-config", #"{"disabled":[],"allowOptionalFailures":false,"logging":true}"#)
                try f.write("get-config-delay", "0.2")
                let backend = GuardBackendFixture()
                let settings = backend.model()
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm, guardSettings: settings)
                settings.refresh()
                try spin { !settings.isBusy }
                settings.selectedInterval = 5
                vm.refresh()
                settings.apply()
                try expect(vm.isBusy && !settings.isApplying && backend.writes.isEmpty, "审计运行时不得启动管理员应用")
                try f.idle(vm)
                vm.loadCheckConfig()
                settings.apply()
                try expect(vm.settingsBusy && !settings.isApplying && backend.writes.isEmpty, "检查设置读取时也不得启动管理员应用")
                try spin { !vm.settingsBusy }
                settings.apply()
                try spin { !settings.isBusy }
                try expect(backend.writes == [5] && settings.current?.verifiedInterval == 5, "VM空闲后应恢复应用能力")
                try expect(delegate.guardSettings === settings, "互斥必须使用控制器注入的同一配置模型")
            case "bodyguard_apply_lifecycle":
                let backend = GuardBackendFixture()
                backend.writeDelay = 0.2
                let settings = backend.model()
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm, guardSettings: settings)
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                settings.refresh()
                try spin { !settings.isBusy }
                settings.selectedInterval = 5
                settings.apply()
                try expect(settings.isApplying && !delegate.canAutoDismiss && vm.canQuit, "应用事务必须独立保护面板，不依赖VM繁忙状态")
                delegate.dismissOnDeactivation()
                delegate.recheckFromMenu()
                try expect(delegate.mainWindow?.isVisible == true && f.calls.isEmpty, "授权期间失焦与菜单重检不能启动审计或收起面板")
                try expect(delegate.applicationShouldTerminate(app) == .terminateCancel, "授权应用期间系统退出也必须被阻止")
                try spin { !settings.isBusy }
                try expect(settings.current?.verifiedInterval == 5 && f.calls.isEmpty, "应用后台周期不能隐式运行核心或切换账号")
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow && delegate.canAutoDismiss, "事务结束后必须解除退出与失焦保护")
                delegate.recheckFromMenu()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status"], "应用完成后菜单重检应恢复原有完整检查链路")
                delegate.hidePanel()
            case "bodyguard_search_operation_guard":
                let backend = GuardBackendFixture()
                backend.writeDelay = 0.2
                let settings = backend.model()
                let vm = f.vm()
                let view = QuickPanelView(vm: vm, onDismiss: {}, guardSettings: settings)
                settings.refresh()
                try spin { !settings.isBusy }
                settings.selectedInterval = 5
                settings.apply()
                try expect(settings.isApplying, "应先进入后台配置应用事务")
                for query in ["B", "修复", "重新检查"] {
                    view.performSearchResult(for: query)
                }
                try expect(f.calls.isEmpty && !vm.isBusy && vm.current == "?", "搜索回车不能绕过授权期间的操作互斥")
                try spin { !settings.isBusy }
                view.performSearchResult(for: "B")
                try f.idle(vm)
                try expect(backend.writes == [5] && settings.current?.verifiedInterval == 5, "搜索操作不得改变后台应用结果")
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"] && vm.current == "B", "事务结束后搜索切换必须恢复完整审计和账号切换")
            case "snapshot_status_semantics":
                let vm = f.vm()
                let initial = WidgetStatusSnapshot.capture(vm, checkedAt: 0)
                try expect(initial.pending == 14 && initial.passed == 0 && initial.menuSummary == "检查中", "初始 pending 不得显示成通过")
                vm.phase = .ready
                try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 42).menuSummary == "待检查", "仍有 pending 时不能显示通过")
                for index in vm.rows.indices { vm.rows[index].state = .ok }
                try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 0).menuSummary == "待检查", "没有检查时间不能显示通过")
                let passed = WidgetStatusSnapshot.capture(vm, checkedAt: 42)
                try expect(passed.passed == 14 && passed.menuSummary == "通过" && passed.symbol == "checkmark.shield", "全部完成时才可显示通过")
                vm.rows[0].state = .warn
                let warning = WidgetStatusSnapshot.capture(vm, checkedAt: 42)
                try expect(warning.passed == 13 && warning.warning == 1 && warning.menuSummary == "有警告" && warning.symbol == "exclamationmark.triangle", "警告必须与通过区分")
                vm.rows[0].state = .skip
                let skipped = WidgetStatusSnapshot.capture(vm, checkedAt: 42)
                try expect(skipped.passed == 13 && skipped.skipped == 1 && skipped.menuSummary == "含跳过" && skipped.symbol == "minus.circle", "跳过必须与通过区分")
                vm.rows[0].state = .fail
                let failed = WidgetStatusSnapshot.capture(vm, checkedAt: 42)
                try expect(failed.failed == 1 && failed.menuSummary == "未通过" && failed.symbol == "exclamationmark.shield", "失败不能被 ready 阶段覆盖")
                vm.rows[0].state = .ok
                vm.phase = .failed
                try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 42).menuSummary == "未通过", "阶段失败不能被全 ok 行覆盖")
                for (phase, title) in [(Phase.checking, "检查中"), (.fixing, "修复中"), (.switching, "切换中")] {
                    vm.phase = phase
                    let snapshot = WidgetStatusSnapshot.capture(vm, checkedAt: 42)
                    try expect(snapshot.menuSummary == title && snapshot.symbol == "arrow.triangle.2.circlepath", "繁忙阶段必须显示当前操作")
                }
                vm.phase = .ready
                vm.rows.removeLast()
                try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 42).menuSummary == "待检查", "不完整结果不能显示通过")
            case "snapshot_privacy":
                let vm = f.vm()
                vm.phase = .ready
                for index in vm.rows.indices { vm.rows[index].state = .ok }
                for account in VM.accountLetters {
                    vm.current = account
                    try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 42).currentAccount == account, "共享状态应保留 A-D 槽位")
                }
                for account in ["none", "未知", "?", "E", "A 198.51.100.23"] {
                    vm.current = account
                    try expect(WidgetStatusSnapshot.capture(vm, checkedAt: 42).currentAccount == "none", "任意账号字符串不得进入共享状态")
                }
                vm.rows[0].detail = "198.51.100.23 Bearer synthetic-secret session=fake"
                vm.banner = "198.51.100.24 cookie=fake"
                vm.fingerprint = "private fingerprint"
                let snapshot = WidgetStatusSnapshot.capture(vm, checkedAt: 42)
                let encoded = try JSONEncoder().encode(snapshot)
                let text = String(decoding: encoded, as: UTF8.self)
                try expect(!text.contains("198.51.100") && !text.contains("Bearer") && !text.contains("synthetic-secret") && !text.contains("cookie") && !text.contains("detail") && !text.contains("fingerprint"), "共享状态不得包含 IP、凭据或原始详情")
                guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw TestFailure(description: "快照不是 JSON 对象") }
                try expect(Set(object.keys) == Set(["schemaVersion", "currentAccount", "status", "checkedAt", "passed", "warning", "failed", "skipped", "pending"]), "共享状态只允许脱敏摘要字段")
                let decoded = try JSONDecoder().decode(WidgetStatusSnapshot.self, from: encoded)
                try expect(decoded == snapshot, "共享状态应可无损解码")
            case "termination_guard":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                let app = NSApplication.shared
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow, "空闲时应该允许退出")
                try f.write("fix-delay", "0.2")
                vm.fixAll()
                try expect(delegate.applicationShouldTerminate(app) == .terminateCancel, "系统退出也必须保护修复操作")
                try f.idle(vm)
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow, "修复结束应该解除退出保护")
            default:
                throw TestFailure(description: "未知测试场景：\(name)")
            }
            print("PASS \(name)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}

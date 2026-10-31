import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Carbon
import Combine
import WidgetKit
import Darwin

// MARK: - 模型

enum RowState { case pending, ok, warn, fail, skip }

struct CheckRow: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var state: RowState = .pending
    var detail: String = ""
}

enum Phase { case checking, ready, failed, switching, done, fixing }

struct CoreResult {
    let output: String
    let succeeded: Bool
}

private struct DesktopUpdateReply: Decodable {
    let state: String
    let version: String?
    let message: String
    let token: String?
}

private enum LatestVersionState { case unchecked, fetching, known, unavailable, failed }

struct AccountStamp: Equatable {
    let size: String
    let date: String
}

// 超时回调与 waitUntilExit 在不同队列上执行。
private final class ProcessDeadline {
    private let lock = NSLock()
    private var expired = false

    func expire(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        expired = true
        process.terminate()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

final class VM: ObservableObject {
    @Published var rows: [CheckRow] = [
        CheckRow(name: "代理内核", icon: "cpu"),
        CheckRow(name: "TUN 网卡", icon: "cable.connector"),
        CheckRow(name: "出口 IP", icon: "globe.americas"),
        CheckRow(name: "IP 与上次一致", icon: "checkmark.seal"),
        CheckRow(name: "时区", icon: "clock"),
        CheckRow(name: "地区", icon: "flag"),
        CheckRow(name: "IPv6 关闭", icon: "6.circle"),
        CheckRow(name: "DNS 走隧道", icon: "magnifyingglass"),
        CheckRow(name: "WebRTC", icon: "eye.slash"),
        CheckRow(name: "保镖在线", icon: "hand.raised"),
        CheckRow(name: "规则置顶", icon: "list.number"),
        CheckRow(name: "客户端语言", icon: "abc"),
        CheckRow(name: "ASN 属性", icon: "building.columns"),
        CheckRow(name: "生态可达性", icon: "antenna.radiowaves.left.and.right"),
    ]
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var archived: Set<String> = []
    @Published var stamps: [String: AccountStamp] = [:]
    @Published var banner = ""
    @Published var note = ""
    @Published var fingerprint = ""
    @Published private(set) var isBusy = false {
        didSet { if isBusy { operationGeneration &+= 1 } }
    }
    @Published private(set) var lastCheckSummary = "尚未检查"
    @Published var updateText = ""
    @Published private(set) var checkingUpdate = false
    @Published private(set) var installingUpdate = false
    @Published private(set) var updateAvailable = false
    @Published private(set) var updateVersion = ""
    @Published private var latestVersionState: LatestVersionState = .unchecked
    @Published var showUpdateSheet = false
    @Published private(set) var coreMissing = false
    @Published private(set) var currentClient = ""
    @Published private(set) var isSwitchingClient = false
    @Published var disabledChecks: Set<String> = []
    @Published var allowOptionalFailures = false
    @Published var loggingEnabled = true
    @Published var settingsMessage = ""
    @Published private(set) var settingsBusy = false
    @Published var showSettingsSheet = false

    static let optionalChecks: [(key: String, label: String)] = [
        ("IP一致", "IP 与上次一致"),
        ("DNS", "DNS 走隧道"),
        ("WebRTC", "WebRTC"),
        ("客户端语言", "客户端语言"),
        ("ASN属性", "ASN 属性"),
        ("生态可达性", "生态可达性"),
    ]

    static let clientChoices: [(key: String, label: String)] = [
        ("clash-verge", "Clash Verge"),
        ("flclash", "FlClash"),
        ("shadowrocket", "Shadowrocket"),
        ("sing-box", "sing-box"),
        ("clashx", "ClashX"),
        ("surge", "Surge"),
    ]

    let core: String
    let installedVersion: String
    private let checkTimeout: TimeInterval
    private let operationTimeout: TimeInterval
    private let monitorInterval: TimeInterval?
    private let monitorTimeout: TimeInterval
    private var monitorTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private(set) var monitorInFlight = false
    private var monitorNeedsAudit = false
    private var operationGeneration: UInt = 0
    private var started = false
    private var switchRequested = false
    private let updateCommand: [String]?
    private let applicationPath: String
    private var updateRestartRequested = false
    private var hideAfterSwitch: DispatchWorkItem?
    var onSwitchCompleted: (() -> Void)?
    var onUpdateRestartReady: (() -> Void)?
    var canMonitor: () -> Bool = { true }

    init(core: String = NSHomeDirectory() + "/.local/bin/claude-switch.sh",
         checkTimeout: TimeInterval = 45, operationTimeout: TimeInterval = 180,
         monitorInterval: TimeInterval? = 10, monitorTimeout: TimeInterval = 3,
         updateCommand: [String]? = nil, applicationPath: String = Bundle.main.bundlePath,
         installedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.core = core
        let version = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.installedVersion = version.isEmpty ? "未知" : version
        self.checkTimeout = checkTimeout
        self.operationTimeout = operationTimeout
        self.monitorInterval = monitorInterval
        self.monitorTimeout = monitorTimeout
        self.applicationPath = applicationPath
        self.updateCommand = updateCommand ?? Bundle.main.path(forResource: "desktop-update", ofType: "py")
            .map { ["/usr/bin/python3", "-I", "-B", $0] }
    }

    var canQuit: Bool {
        !switchRequested && phase != .fixing && phase != .switching
            && (!installingUpdate || updateRestartRequested)
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        if let interval = monitorInterval, interval > 0 {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.pollEnvironment()
            }
            // 菜单追踪期间和主窗口隐藏时仍采样，不依赖 SwiftUI 视图生命周期。
            RunLoop.main.add(timer, forMode: .common)
            monitorTimer = timer
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.pollEnvironment() }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        // 已发出的只读采样也不能在停止后发布结果。
        invalidateMonitorSample()
    }

    func invalidateMonitorSample() { operationGeneration &+= 1 }

    deinit { stopMonitoring() }

    func pollEnvironment() {
        guard started, !isBusy, !settingsBusy, !monitorInFlight, canMonitor() else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        monitorInFlight = true
        let generation = operationGeneration
        // 不占用前台操作锁；前台操作开始后丢弃旧采样，避免迟到结果覆盖修复/切换。
        run(["monitor-status"], timeout: monitorTimeout) { [weak self] result in
            guard let self = self else { return }
            self.monitorInFlight = false
            guard generation == self.operationGeneration, !self.isBusy,
                  !self.settingsBusy, self.canMonitor() else { return }
            let lines = result.output.split(separator: "\n").map(String.init)
            var states: [String: RowState] = [:]
            var valid = result.succeeded && lines.count == 3 && lines.first == "monitor-version=1"
            for line in lines.dropFirst() {
                let pair = line.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
                guard pair.count == 2, ["代理内核", "TUN网卡"].contains(pair[0]),
                      states[pair[0]] == nil, ["ok", "fail"].contains(pair[1]) else {
                    valid = false; continue
                }
                states[pair[0]] = pair[1] == "ok" ? .ok : .fail
            }
            valid = valid && states.count == 2
            let keys = [("代理内核", "代理内核"), ("TUN网卡", "TUN 网卡")]
            if valid && states.values.allSatisfy({ $0 == .ok }) {
                // 局部健康不等于完整安检通过，恢复后必须重新完成全部审计。
                if self.monitorNeedsAudit || self.coreMissing || keys.contains(where: { key in
                    self.rows.contains { $0.name == key.1 && $0.state == .fail }
                }) {
                    self.monitorNeedsAudit = false
                    self.refresh()
                }
                return
            }
            self.hideAfterSwitch?.cancel()
            self.monitorNeedsAudit = true
            for (key, name) in keys {
                guard let index = self.rows.firstIndex(where: { $0.name == name }) else { continue }
                self.rows[index].state = valid ? (states[key] ?? .fail) : .fail
                self.rows[index].detail = valid
                    ? (states[key] == .ok ? "后台监测：在线" : "后台监测：不在线")
                    : "后台状态未确认，请重新检查并确认核心脚本为新版"
            }
            self.phase = .failed
            self.lastCheckSummary = "失败"
            self.banner = valid ? "后台监测发现代理内核或 TUN 离线，恢复后将自动重新检查"
                : "后台状态读取失败，无法确认代理安全；请重新检查并确认核心脚本为新版"
        }
    }

    func prepareToShow() {
        hideAfterSwitch?.cancel()
        if phase == .done { phase = .ready }
    }

    private func run(_ args: [String], timeout: TimeInterval = 45, done: @escaping (CoreResult) -> Void) {
        execute(["/bin/bash", core] + args, timeout: timeout, done: done)
    }

    private func execute(_ command: [String], timeout: TimeInterval,
                         rawFailure: Bool = false, done: @escaping (CoreResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-out-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let fh = try? FileHandle(forWritingTo: tmp) else {
                DispatchQueue.main.async { done(CoreResult(output: "无法创建检查输出文件", succeeded: false)) }
                return
            }
            defer {
                try? fh.close()
                try? FileManager.default.removeItem(at: tmp)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command[0])
            p.arguments = Array(command.dropFirst())
            p.standardOutput = fh
            p.standardError = fh
            do { try p.run() } catch {
                DispatchQueue.main.async { done(CoreResult(output: "无法启动脚本：\(error.localizedDescription)", succeeded: false)) }
                return
            }
            let deadline = ProcessDeadline()
            let watchdog = DispatchWorkItem { deadline.expire(p) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            p.waitUntilExit()
            watchdog.cancel()
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let result: CoreResult
            if deadline.timedOut {
                result = CoreResult(output: "操作超时，请重试", succeeded: false)
            } else if p.terminationStatus != 0 {
                result = CoreResult(output: rawFailure ? out : "脚本执行失败（退出码 \(p.terminationStatus)）\n\(out)", succeeded: false)
            } else {
                result = CoreResult(output: out, succeeded: true)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        hideAfterSwitch?.cancel()
        if !coreAvailable() { markCoreMissing(); return }
        isBusy = true
        checkEnvironment { _ in self.isBusy = false }
    }

    private func coreAvailable() -> Bool {
        FileManager.default.isReadableFile(atPath: core)
    }

    private func markCoreMissing() {
        coreMissing = true
        phase = .failed
        lastCheckSummary = "未安装核心脚本"
        banner = "未安装核心脚本：请下载 installer-kit 安装包并双击 installer/安装.command，或运行源码安装"
        for i in rows.indices {
            rows[i].state = .fail
            rows[i].detail = "未安装核心脚本"
        }
    }

    func refreshAccountStatus() {
        // 菜单展开时只读取本地账号状态，不触发网络审计；启动审计优先。
        guard started, !isBusy else { return }
        isBusy = true
        run(["status"], timeout: checkTimeout) { result in
            self.updateStatus(result)
            self.isBusy = false
        }
    }

    private func checkEnvironment(done: @escaping (Bool) -> Void) {
        if !coreAvailable() {
            markCoreMissing()
            done(false)
            return
        }
        coreMissing = false
        monitorNeedsAudit = false
        phase = .checking
        lastCheckSummary = "检查中"
        banner = ""
        note = ""
        for i in rows.indices { rows[i].state = .pending; rows[i].detail = "" }
        run(["checkdetail"], timeout: checkTimeout) { result in
            var allOk = result.succeeded
            var matched = Set<Int>()
            var duplicated = false
            let keyMap: [String: String] = [
                "代理内核": "代理内核", "TUN网卡": "TUN 网卡", "出口IP": "出口 IP",
                "IP一致": "IP 与上次一致", "时区": "时区", "地区": "地区",
                "IPv6": "IPv6 关闭", "DNS": "DNS 走隧道", "WebRTC": "WebRTC",
                "保镖": "保镖在线", "规则置顶": "规则置顶",
                "客户端语言": "客户端语言", "ASN属性": "ASN 属性", "生态可达性": "生态可达性",
            ]
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let rowName = keyMap[parts[0]],
                      let idx = self.rows.firstIndex(where: { $0.name == rowName }) else { continue }
                // 重复行不能补齐缺失项，也不能用后来的 ok 覆盖先前的 fail。
                guard matched.insert(idx).inserted else { allOk = false; duplicated = true; continue }
                let status = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                switch status.first ?? "" {
                case "ok": self.rows[idx].state = .ok
                case "warn": self.rows[idx].state = .warn
                case "skip": self.rows[idx].state = .skip
                default: self.rows[idx].state = .fail; allOk = false
                }
                self.rows[idx].detail = status.count > 1 ? status[1] : ""
            }
            if !result.succeeded {
                self.banner = result.output.isEmpty ? "核心脚本执行失败" : result.output
                for i in self.rows.indices where self.rows[i].state == .pending {
                    self.rows[i].state = .fail
                    self.rows[i].detail = "核心脚本执行失败"
                }
            } else if duplicated {
                self.banner = "检测输出存在重复项，请重新检查"
            } else if matched.count != self.rows.count {
                self.banner = "检测输出不完整(\(matched.count)/\(self.rows.count))，请点重新检查"
            }
            let passed = allOk && matched.count == self.rows.count
            self.lastCheckSummary = passed
                ? (self.rows.contains { $0.state == .warn }
                    ? "有警告"
                    : (self.rows.contains { $0.state == .skip } ? "通过（含跳过）" : "通过"))
                : "失败"
            self.run(["get-client"], timeout: self.checkTimeout) { clientResult in
                self.updateClient(clientResult)
                self.run(["status"], timeout: self.checkTimeout) { status in
                    let statusOK = self.updateStatus(status)
                    if !statusOK {
                        if !passed || self.banner.isEmpty {
                            self.banner = "无法读取账号状态，请重新检查"
                        }
                        self.lastCheckSummary = "失败"
                    }
                    self.phase = passed && statusOK ? .ready : .failed
                    done(passed && statusOK)
                }
            }
        }
    }

    @discardableResult
    private func updateStatus(_ result: CoreResult) -> Bool {
        let fields = result.output.split(whereSeparator: { $0.isWhitespace }).reduce(into: [String: String]()) { values, field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        func reset() -> Bool {
            current = "未知"; archived = []; stamps = [:]
            return false
        }
        guard result.succeeded, let account = fields["current"],
              ["A", "B", "C", "D", "none"].contains(account) else {
            return reset()
        }
        var known = Set<String>()
        if let list = fields["accounts"] {
            if list != "none" {
                for piece in list.split(separator: ",", omittingEmptySubsequences: true) {
                    let letter = String(piece)
                    guard Self.accountLetters.contains(letter) else { return reset() }
                    known.insert(letter)
                }
            }
        } else {
            // 旧版核心只输出 current/hasA/hasB,继续兼容已安装的旧脚本。
            for letter in ["A", "B"] {
                guard let flag = fields["has\(letter)"], ["0", "1"].contains(flag) else { return reset() }
                if flag == "1" { known.insert(letter) }
            }
        }
        var parsed: [String: AccountStamp] = [:]
        for letter in Self.accountLetters {
            guard let raw = fields["acc\(letter)"] else { continue }
            let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return reset() }
            parsed[letter] = AccountStamp(size: String(parts[0]), date: String(parts[1]))
        }
        current = account == "none" ? "未初始化" : account
        stamps = parsed
        archived = known
        return true
    }

    static let accountLetters = ["A", "B", "C", "D"]

    private func updateClient(_ result: CoreResult) {
        guard result.succeeded else { return }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 && parts[0] == "client" {
                currentClient = parts[1]
            }
        }
    }

    func loadCheckConfig() {
        guard !settingsBusy, coreAvailable() else { return }
        settingsBusy = true
        settingsMessage = "正在读取设置…"
        run(["get-check-config"]) { result in
            self.settingsBusy = false
            guard result.succeeded,
                  let data = result.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let config = object as? [String: Any],
                  let disabled = config["disabled"] as? [String],
                  let allow = config["allowOptionalFailures"] as? Bool,
                  let logging = config["logging"] as? Bool,
                  Set(disabled).count == disabled.count,
                  disabled.allSatisfy({ name in Self.optionalChecks.contains { $0.key == name } }) else {
                self.settingsMessage = "读取检查设置失败，请恢复默认后重试"
                return
            }
            self.disabledChecks = Set(disabled)
            self.allowOptionalFailures = allow
            self.loggingEnabled = logging
            self.settingsMessage = ""
        }
    }

    func saveCheckConfig() {
        guard !isBusy, !settingsBusy, coreAvailable() else { return }
        let allowed = Set(Self.optionalChecks.map { $0.key })
        guard disabledChecks.isSubset(of: allowed) else {
            settingsMessage = "包含不允许关闭的安全检查"
            return
        }
        let config: [String: Any] = [
            "disabled": Self.optionalChecks.map { $0.key }.filter { disabledChecks.contains($0) },
            "allowOptionalFailures": allowOptionalFailures,
            "logging": loggingEnabled,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        settingsBusy = true
        settingsMessage = "正在保存…"
        run(["set-check-config", json]) { result in
            self.settingsBusy = false
            self.settingsMessage = result.succeeded ? "设置已保存，正在重新检查" : result.output
            if result.succeeded { self.refresh() }
        }
    }

    func restoreCheckDefaults() {
        disabledChecks = []
        allowOptionalFailures = false
        loggingEnabled = true
        settingsMessage = "已恢复默认选项，点击保存后生效"
    }

    func exportDiagnostics() {
        guard !settingsBusy, coreAvailable() else { return }
        let panel = NSSavePanel()
        panel.title = "导出脱敏诊断日志"
        panel.message = "仅包含检查状态、设置和脱敏操作日志，不含 IP、凭据、账号或代理配置。"
        panel.nameFieldStringValue = "claude-switcher-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        settingsBusy = true
        settingsMessage = "正在导出诊断日志…"
        run(["export-diagnostics", destination.path], timeout: operationTimeout) { result in
            self.settingsBusy = false
            let message = result.succeeded ? result.output : "导出失败：\(result.output)"
            self.settingsMessage = message
            let alert = NSAlert()
            alert.messageText = result.succeeded ? "诊断日志已导出" : "诊断日志导出失败"
            alert.informativeText = message
            alert.alertStyle = result.succeeded ? .informational : .warning
            alert.runModal()
        }
    }

    func setClient(_ key: String) {
        guard !isBusy, !isSwitchingClient else { return }
        guard Self.clientChoices.contains(where: { $0.key == key }) else { return }
        guard key != currentClient else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        isBusy = true
        isSwitchingClient = true
        banner = "正在切换代理客户端…"
        run(["set-client", key], timeout: operationTimeout) { result in
            self.isSwitchingClient = false
            guard result.succeeded else {
                self.banner = result.output
                self.isBusy = false
                return
            }
            // 切换后重新完成环境审计,刷新「代理内核」等检查项
            self.currentClient = key
            self.checkEnvironment { _ in self.isBusy = false }
        }
    }

    func fixAll() {
        guard !isBusy else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        hideAfterSwitch?.cancel()
        isBusy = true
        phase = .fixing
        banner = "正在修复…（若弹出密码框请输入开机密码）"
        run(["fix"], timeout: operationTimeout) { result in
            guard result.succeeded else {
                self.banner = result.output; self.phase = .failed; self.isBusy = false
                return
            }
            self.checkEnvironment { _ in self.isBusy = false }
        }
    }

    func inspectFingerprint() {
        guard !isBusy else { return }
        isBusy = true
        fingerprint = "正在体检…"
        run(["fingerprint"], timeout: 90) { result in
            self.fingerprint = result.output
            self.isBusy = false
        }
    }

    func checkUpdate() {
        guard !checkingUpdate, !isBusy, !settingsBusy, canMonitor() else { return }
        checkingUpdate = true
        updateAvailable = false
        updateVersion = ""
        latestVersionState = .fetching
        updateText = "正在检查更新…"
        runUpdate(["check"], timeout: 240) { result in
            self.checkingUpdate = false
            guard let reply = self.updateReply(result, allowed: ["available", "current", "unavailable"]) else {
                self.latestVersionState = .failed
                return
            }
            if reply.state == "unavailable" {
                self.latestVersionState = .unavailable
                self.updateText = reply.message
                return
            }
            guard let version = reply.version, Self.isReleaseVersion(version) else {
                self.latestVersionState = .failed
                self.updateText = "GitHub 返回的正式版本号无效，请重试"
                return
            }
            self.updateAvailable = reply.state == "available"
            self.updateVersion = version
            self.latestVersionState = .known
            self.updateText = reply.message
        }
    }

    var latestReleaseVersionLabel: String {
        switch latestVersionState {
        case .unchecked: return "未检查"
        case .fetching: return "正在获取…"
        case .known: return updateVersion
        case .unavailable: return "暂无正式发布"
        case .failed: return "获取失败"
        }
    }

    private static func isReleaseVersion(_ version: String) -> Bool {
        guard version.count <= 64,
              let range = version.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$",
                                        options: .regularExpression) else { return false }
        return range == version.startIndex..<version.endIndex
    }

    var canInstallUpdate: Bool {
        latestVersionState == .known && Self.isReleaseVersion(updateVersion)
            && !checkingUpdate && !installingUpdate && !isBusy && !settingsBusy && canMonitor()
    }

    func requestInstallUpdate() {
        guard canInstallUpdate else { return }
        let alert = NSAlert()
        alert.messageText = updateAvailable ? "更新 Claude 切换器并重启？" : "校验并修复当前版本组件？"
        alert.informativeText = updateAvailable
            ? "将更新切换器并自动重启，保留账号和设置。安装失败时自动回滚；Claude 启动前仍需通过安全检查。"
            : "会下载当前正式版本，按需修复组件并保留账号和设置。安装失败时自动回滚；Claude 启动前仍需通过安全检查。"
        alert.addButton(withTitle: updateAvailable ? "更新并重启" : "校验并修复")
        alert.addButton(withTitle: "取消")
        installUpdate(confirmed: alert.runModal() == .alertFirstButtonReturn)
    }

    // 确认与执行分开，模型回归不弹窗，也不调用本机安装态。
    func installUpdate(confirmed: Bool) {
        guard confirmed, canInstallUpdate else { return }
        installingUpdate = true
        isBusy = true
        updateRestartRequested = false
        updateText = "正在下载并校验正式版本…\n完成后将自动重启切换器，请稍候。"
        runUpdate(["prepare"], timeout: 600) { result in
            guard let reply = self.updateReply(result, allowed: ["prepared", "current"]) else {
                self.finishUpdateFailure(); return
            }
            if reply.state == "current" {
                self.updateAvailable = false
                self.updateText = reply.message
                self.finishUpdateFailure()
                return
            }
            guard let token = reply.token, UUID(uuidString: token) != nil else {
                self.updateText = "更新组件未返回有效的更新凭据，未替换安装版本"
                self.finishUpdateFailure(); return
            }
            self.updateText = "更新已准备，正在安排重启…"
            self.runUpdate(["apply", "--token", token, "--pid", String(ProcessInfo.processInfo.processIdentifier)], timeout: 30) { result in
                guard let reply = self.updateReply(result, allowed: ["restarting"]) else {
                    self.finishUpdateFailure(); return
                }
                self.updateText = reply.message
                self.updateRestartRequested = true
                self.stopMonitoring()
                self.onUpdateRestartReady?()
            }
        }
    }

    func acknowledgeUpdate(token: String) {
        guard UUID(uuidString: token) != nil else { return }
        runUpdate(["ack", "--token", token], timeout: 15) { result in
            guard let reply = self.updateReply(result, allowed: ["updated"]) else {
                self.showUpdateSheet = true; return
            }
            self.updateAvailable = false
            self.updateText = reply.message
            self.showUpdateSheet = true
        }
    }

    private func finishUpdateFailure() {
        installingUpdate = false
        isBusy = false
        updateRestartRequested = false
    }

    private func runUpdate(_ args: [String], timeout: TimeInterval, done: @escaping (CoreResult) -> Void) {
        guard let command = updateCommand, !command.isEmpty else {
            done(CoreResult(output: "当前 App 缺少更新组件，请先安装新版 App 后使用界面更新", succeeded: false))
            return
        }
        execute(command + args + ["--app", applicationPath, "--core", core], timeout: timeout,
                rawFailure: true, done: done)
    }

    private func updateReply(_ result: CoreResult, allowed: Set<String>) -> DesktopUpdateReply? {
        guard let data = result.output.data(using: .utf8), data.count < 16384,
              let reply = try? JSONDecoder().decode(DesktopUpdateReply.self, from: data) else {
            updateText = result.output == "操作超时，请重试" ? "更新操作超时，请重试；未确认完成的更新不会显示成功"
                : "更新组件未返回有效结果，请确认 App 更新组件已安装并重试"
            if updateCommand == nil { updateText = "当前 App 缺少更新组件，请先安装新版 App 后使用界面更新" }
            return nil
        }
        guard result.succeeded, allowed.contains(reply.state), !reply.message.isEmpty else {
            updateText = reply.state == "error" && !reply.message.isEmpty ? reply.message : "更新操作未完成，请重试"
            return nil
        }
        return reply
    }

    var aiPrompt: String {
        let home = NSHomeDirectory()
        let agents = home + "/.claude-switcher/AGENTS.md"
        let agentsLine = FileManager.default.fileExists(atPath: agents)
            ? "本机交接文档：\(agents)"
            : "本机交接文档：\(agents)（~/.claude-switcher 不存在或其中没有 AGENTS.md，请从仓库根目录读取 AGENTS.md）"
        return """
        这是「Claude 切换器」的 AI 交接提示词。请先完整阅读交接文档，再开始安装、配置或排障。

        仓库地址：https://github.com/chenchao19934/claude-switcher
        \(agentsLine)

        执行要求：
        1. 先读 AGENTS.md，按其中的安装步骤、验收标准与安全红线执行，不要只凭本段提示词猜测。
        2. 安装或排障时先跑环境审计：硬性安全项必须通过；只有显式配置的非关键项可跳过或降为警告，skip 不表示检查通过。
        3. 账号切换前先完全退出 Claude；账号快照按 AGENTS.md 的规则保留，不要改动 ~/.claude-switcher/accounts/ 的结构。
        4. 保镖等常驻脚本只放在 root 所有的系统目录，不要改回用户可写路径；需要变更时引导我重跑安装器。
        5. 不要未经我明确同意更新、覆盖或重装已安装版本（~/.local/bin、桌面 App、launchd 与系统目录），也不要执行 update 或安装器；先说明影响并征得同意。
        6. 检查新版本只运行 `~/.local/bin/claude-switch.sh update-check`，看到结果后先问我是否执行更新。
        7. 不要在日志、文档或回复里暴露我的出口 IP、代理地址或任何凭据。
        """
    }

    func switchTo(_ target: String) {
        guard !isBusy, Self.accountLetters.contains(target) else { return }
        hideAfterSwitch?.cancel()
        isBusy = true
        switchRequested = true
        // 常驻后旧检查可能已经过期。每次切换都重新审计，不使用落盘的旧结果放行。
        checkEnvironment { passed in
            guard passed else {
                self.switchRequested = false; self.isBusy = false
                return
            }
            self.performSwitch(target)
        }
    }

    private func performSwitch(_ target: String) {
        phase = .switching
        banner = "正在切换到账号 \(target)…"
        run(["switch", target], timeout: operationTimeout) { [self] result in
            let lines = result.output.split(separator: "\n").map(String.init)
            let failure = lines.first { $0.hasPrefix("FAIL:") }
            let success = lines.contains { $0.hasPrefix("OK:") || $0.hasPrefix("INFO:") }
            guard result.succeeded, failure == nil, success else {
                self.phase = .failed
                self.banner = failure.map { String($0.dropFirst(5)) } ?? (result.output.isEmpty ? "切换未返回成功结果，请重新检查" : result.output)
                self.switchRequested = false; self.isBusy = false
                return
            }
            var extra = ""
            if target != "A" && !self.archived.contains(target) {
                extra = "\(target) 号首次使用：请在打开的 Claude 里登录 \(target) 账号，登录一次即可。"
            }
            let unchanged = lines.contains { $0.hasPrefix("INFO:") }
            if unchanged { extra = "" }
            self.current = target
            self.phase = .done
            self.banner = unchanged ? "当前已是账号 \(target)" : "已切换到账号 \(target)"
            self.note = extra
            self.switchRequested = false; self.isBusy = false
            let hide = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .done, !self.isBusy else { return }
                self.onSwitchCompleted?()
                self.phase = .ready
            }
            self.hideAfterSwitch = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: hide)
        }
    }
}

// MARK: - Claude 风格外观

enum ClaudeTheme {
    // 纸感暖色基底 (Warm Parchment / Alabaster)
    static let bgTop = Color(red: 0.984, green: 0.976, blue: 0.961)         // #FAF9F5
    static let bgBottom = Color(red: 0.957, green: 0.945, blue: 0.925)      // #F4F1EC
    static let card = Color.white                                           // #FFFFFF
    static let cardBorder = Color(red: 0.898, green: 0.882, blue: 0.855)   // #E5E1DA
    static let divider = Color(red: 0.941, green: 0.929, blue: 0.910)      // #F0ECE8
    static let iconWell = Color(red: 0.965, green: 0.953, blue: 0.937)     // #F6F3EF

    // 字体色阶 (Editorial Ink & Warm Stone)
    static let ink = Color(red: 0.165, green: 0.153, blue: 0.141)          // #2A2724
    static let muted = Color(red: 0.455, green: 0.435, blue: 0.412)        // #746F69

    // Claude 标志性陶土橙 (Anthropic Claude Terracotta)
    static let terracotta = Color(red: 0.847, green: 0.447, blue: 0.329)   // #D87254
    static let terracottaDeep = Color(red: 0.761, green: 0.369, blue: 0.259) // #C25E42
    static let terracottaTint = Color(red: 0.847, green: 0.447, blue: 0.329).opacity(0.09)

    // 自然柔和状态色
    static let success = Color(red: 0.180, green: 0.490, blue: 0.322)       // #2E7D52 (Sage Green)

    static let warning = Color(red: 0.722, green: 0.431, blue: 0.094)       // #B86E18 (Warm Amber)
    static let warningBorder = Color(red: 0.961, green: 0.863, blue: 0.718) // #F5DCB7

    static let error = Color(red: 0.761, green: 0.282, blue: 0.212)         // #C24836 (Claude Terracotta Red)
}

// MARK: - Claude 优雅背景

struct ClaudeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ClaudeTheme.bgTop, ClaudeTheme.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [ClaudeTheme.terracotta.opacity(0.04), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 辅助样式组件

struct ClaudeIconButton: View {
    let systemName: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? ClaudeTheme.ink : ClaudeTheme.muted)
                .frame(width: 28, height: 28)
                .background(isHovered ? ClaudeTheme.iconWell : ClaudeTheme.card.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 7.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 7.5)
                        .stroke(isHovered ? ClaudeTheme.cardBorder : ClaudeTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(help)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var vm: VM
    var height: CGFloat = 900
    @State private var showNotice = false
    @State private var showFingerprint = false
    @State private var showAIPrompt = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 12) {
                header
                HStack {
                    Text("环境检查").font(.caption.weight(.semibold)).foregroundColor(ClaudeTheme.muted)
                    Spacer()
                    statusPill
                }
                // 小屏上窗口高度会被系统可见区域压缩,让卡片区可滚动而不是被裁切
                ScrollView {
                    VStack(spacing: 16) {
                        checksCard
                        clientCard
                        if vm.phase == .ready || vm.phase == .switching || vm.phase == .done {
                            accountCard
                        } else if vm.coreMissing {
                            setupCard
                        } else if vm.phase == .failed || vm.phase == .fixing {
                            retryCard
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                footer
            }
            .padding(16)
        }
        .sheet(isPresented: $showAIPrompt) { AIPromptSheet(text: vm.aiPrompt) }
        .sheet(isPresented: $vm.showSettingsSheet) { CheckSettingsView(vm: vm) }
        .frame(width: 440, height: height)
        .preferredColorScheme(.light)
    }

    var header: some View {
        HStack(spacing: 11) {
            // Claude 风格陶土盾牌徽标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: ClaudeTheme.terracotta.opacity(0.24), radius: 3.5, x: 0, y: 1.5)

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude 账号切换器")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundColor(ClaudeTheme.ink)
                Text("安全检查 · 切换 · 启动")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(ClaudeTheme.muted)
            }

            Spacer()

            ClaudeIconButton(
                systemName: "waveform.path.ecg",
                help: "设备指纹体检(字体/GPU/虚拟机)",
                disabled: vm.isBusy
            ) {
                showFingerprint = true
                vm.inspectFingerprint()
            }

            ClaudeIconButton(
                systemName: "gearshape",
                help: "检查设置与诊断日志"
            ) {
                vm.showSettingsSheet = true
            }

            ClaudeIconButton(
                systemName: "info.circle",
                help: "安全防护体系公告"
            ) {
                showNotice = true
            }

        }
        .sheet(isPresented: $showNotice) { NoticeView() }
        .sheet(isPresented: $showFingerprint) { FingerprintView(text: vm.fingerprint) }
    }

    var statusPill: some View {
        let (txt, color): (String, Color) = {
            switch vm.phase {
            case .checking: return ("检查中", ClaudeTheme.terracottaDeep)
            case .ready: return ("环境安全", ClaudeTheme.success)
            case .failed: return ("检查未过", ClaudeTheme.error)
            case .switching: return ("切换中", ClaudeTheme.terracottaDeep)
            case .fixing: return ("修复中", ClaudeTheme.terracottaDeep)
            case .done: return ("完成", ClaudeTheme.success)
            }
        }()
        return Text(txt)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    var checksCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.rows.enumerated()), id: \.element.id) { idx, row in
                HStack(spacing: 10) {
                    // 左侧图标容器
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ClaudeTheme.iconWell)
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(ClaudeTheme.divider, lineWidth: 0.5)
                            )
                        Image(systemName: row.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(ClaudeTheme.muted)
                    }

                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ClaudeTheme.ink)

                    Spacer(minLength: 8)

                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11.5, weight: .regular, design: isMonospace(row.detail) ? .monospaced : .default))
                            .foregroundColor(row.state == .warn ? ClaudeTheme.warning : ClaudeTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    stateIcon(row.state)
                }
                .padding(.vertical, 5.5)
                .padding(.horizontal, 12)

                if idx < vm.rows.count - 1 {
                    Divider()
                        .overlay(ClaudeTheme.divider)
                        .padding(.leading, 46)
                }
            }
        }
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(ClaudeTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color(red: 0.2, green: 0.16, blue: 0.12).opacity(0.035), radius: 6, x: 0, y: 2)
    }

    private func isMonospace(_ str: String) -> Bool {
        str.contains(".") || str.contains(":") || str.contains("/")
    }

    var clientCard: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ClaudeTheme.iconWell)
                    .frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ClaudeTheme.divider, lineWidth: 0.5))
                Image(systemName: "network")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(ClaudeTheme.muted)
            }
            Text("代理客户端").font(.system(size: 13, weight: .medium)).foregroundColor(ClaudeTheme.ink)
            Spacer()
            if vm.isSwitchingClient {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            }
            Picker("", selection: Binding(
                get: { vm.currentClient },
                set: { vm.setClient($0) }
            )) {
                ForEach(VM.clientChoices, id: \.key) { choice in
                    Text(choice.label).tag(choice.key)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(vm.isBusy || vm.isSwitchingClient)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(ClaudeTheme.cardBorder, lineWidth: 1))
        .shadow(color: Color(red: 0.2, green: 0.16, blue: 0.12).opacity(0.035), radius: 6, x: 0, y: 2)
    }

    func stateIcon(_ s: RowState) -> some View {
        Group {
            switch s {
            case .pending: ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(ClaudeTheme.success)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(ClaudeTheme.warning)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundColor(ClaudeTheme.error)
            case .skip: Image(systemName: "minus.circle").foregroundColor(ClaudeTheme.muted)
            }
        }
        .font(.callout)
    }

    var accountCard: some View {
        VStack(spacing: 12) {
            if vm.phase == .switching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.ink)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else if vm.phase == .done {
                VStack(spacing: 4) {
                    Label(vm.banner, systemImage: "checkmark.circle.fill").foregroundColor(ClaudeTheme.success).font(.callout.bold())
                    if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundColor(ClaudeTheme.warning).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                HStack(spacing: 6) {
                    Text("当前账号").font(.caption).foregroundColor(ClaudeTheme.muted)
                    Text(vm.current).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(ClaudeTheme.terracottaTint).foregroundColor(ClaudeTheme.terracottaDeep)
                        .clipShape(Capsule())
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(VM.accountLetters, id: \.self) { t in
                        accountButton(t, subtitle: accountSubtitle(t))
                    }
                }
            }
        }
        .padding(12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    func accountSubtitle(_ t: String) -> String {
        if vm.current == t { return "当前" }
        guard vm.archived.contains(t) else { return "未初始化" }
        guard let stamp = vm.stamps[t] else { return "已建档" }
        return "已建档 · \(stamp.size) · \(shortDate(stamp.date))"
    }

    func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4 else { return value }
        return "\(parts[1])-\(parts[2])"
    }

    func accountButton(_ t: String, subtitle: String) -> some View {
        Button { vm.switchTo(t) } label: {
            VStack(spacing: 4) {
                Text("账号 \(t)").font(.headline).foregroundColor(vm.current == t ? .white : ClaudeTheme.ink)
                Text(subtitle).font(.caption2).foregroundColor(vm.current == t ? .white.opacity(0.9) : ClaudeTheme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(
                vm.current == t
                ? LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [ClaudeTheme.iconWell, ClaudeTheme.iconWell], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(vm.current == t ? ClaudeTheme.terracotta : ClaudeTheme.cardBorder, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
    }

    var setupCard: some View {
        VStack(spacing: 10) {
            Text("还差一步：安装核心脚本").font(.callout.bold()).foregroundColor(ClaudeTheme.ink)
            Text(vm.banner).font(.caption).foregroundColor(ClaudeTheme.muted).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { openURL("https://github.com/chenchao19934/claude-switcher/releases/latest") } label: {
                    Label("打开下载页", systemImage: "arrow.down.circle")
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { openURL("https://github.com/chenchao19934/claude-switcher#安装") } label: {
                    Label("安装说明", systemImage: "book")
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(ClaudeTheme.iconWell)
                        .foregroundColor(ClaudeTheme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(ClaudeTheme.error.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.error.opacity(0.25)))
    }

    private func openURL(_ text: String) {
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }

    var retryCard: some View {
        VStack(spacing: 10) {
            if vm.phase == .fixing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.ink)
                }
            } else {
                if !vm.banner.isEmpty {
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.error).multilineTextAlignment(.center)
                }
                Text("存在未通过项，可一键修复或手动处理后重试").font(.caption).foregroundColor(ClaudeTheme.muted)
                HStack(spacing: 10) {
                    Button { vm.fixAll() } label: {
                        Label("一键修复", systemImage: "wand.and.stars")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                    Button { vm.refresh() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.warningBorder))
    }

    var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.caption2)
            Text("硬性安全项必须通过；灰色跳过不表示检查通过").font(.caption2)
            Spacer()
            Button {
                vm.checkUpdate()
                vm.showUpdateSheet = true
            } label: {
                Text("检查更新").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("检查更新")
            Button { showAIPrompt = true } label: {
                Text("AI 配置").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI 配置")
        }
        .foregroundColor(ClaudeTheme.muted)
        .sheet(isPresented: $vm.showUpdateSheet) { UpdateSheet(vm: vm) }
    }
}

// MARK: - 检查设置与诊断

struct CheckSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("检查设置").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("安全项始终强制执行；跳过不等于通过").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("可自定义的非关键检查") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(VM.optionalChecks, id: \.key) { item in
                                    Toggle(item.label, isOn: Binding(
                                        get: { !vm.disabledChecks.contains(item.key) },
                                        set: { enabled in
                                            if enabled { vm.disabledChecks.remove(item.key) }
                                            else { vm.disabledChecks.insert(item.key) }
                                        }
                                    ))
                                }
                                Text("关闭后会真正跳过对应探测，并以灰色“已跳过”显示。出口国家、代理/TUN、Kill-Switch、保镖、账号归档和更新校验不可关闭。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("失败处理与日志") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("将上述非关键项的失败降为警告", isOn: $vm.allowOptionalFailures)
                                Text("只影响这 6 项；不会放宽任何硬性安全项，也不会自动关闭检测。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                                Toggle("记录脱敏客户端日志", isOn: $vm.loggingEnabled)
                                Text("仅记录版本、命令、退出码、耗时和检查状态，不记录 IP、凭据或账号内容。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("问题排查") {
                            VStack(alignment: .leading, spacing: 9) {
                                Button("导出脱敏诊断日志…") { vm.exportDiagnostics() }
                                    .disabled(vm.settingsBusy)
                                Text("日志：~/Library/Logs/claude-switcher/client.log")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted).textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                if !vm.settingsMessage.isEmpty {
                    Text(vm.settingsMessage).font(.caption).foregroundColor(ClaudeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("恢复默认") { vm.restoreCheckDefaults() }.disabled(vm.settingsBusy)
                    Spacer()
                    if vm.settingsBusy { ProgressView().scaleEffect(0.65) }
                    Button("保存并重新检查") { vm.saveCheckConfig() }
                        .buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
                        .disabled(vm.settingsBusy || vm.isBusy)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 610)
        .preferredColorScheme(.light)
        .onAppear { vm.loadCheckConfig() }
    }
}

// MARK: - 设备指纹体检

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备指纹体检").font(.headline).foregroundColor(ClaudeTheme.ink)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
            }
            Text("字体地区特征 + GPU/虚拟机特征；Canvas/WebGL 请用 Web 检测页")
                .font(.caption).foregroundColor(ClaudeTheme.muted)
            ScrollView {
                Text(text.isEmpty ? "正在体检…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(ClaudeTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .preferredColorScheme(.light)
        .background(ClaudeTheme.bgTop)
    }
}

// MARK: - 版本更新

struct UpdateControls: View {
    @ObservedObject var vm: VM

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前版本").font(.caption).foregroundColor(ClaudeTheme.muted)
                    Text(vm.installedVersion)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text("GitHub 最新正式版本").font(.caption).foregroundColor(ClaudeTheme.muted)
                    Text(vm.latestReleaseVersionLabel)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundColor(vm.updateVersion.isEmpty ? ClaudeTheme.muted : ClaudeTheme.ink)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(ClaudeTheme.iconWell)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Button(vm.checkingUpdate ? "正在检查…" : "重新检查") { vm.checkUpdate() }
                    .disabled(vm.checkingUpdate || vm.isBusy || vm.settingsBusy)
                Button(vm.installingUpdate ? "正在更新…" : (vm.updateAvailable ? "更新并重启" : "校验并修复组件")) { vm.requestInstallUpdate() }
                    .buttonStyle(.borderedProminent)
                    .tint(ClaudeTheme.terracottaDeep)
                    .disabled(!vm.canInstallUpdate)
                if vm.checkingUpdate || vm.installingUpdate { ProgressView().controlSize(.small) }
            }
            Text("更新会保留账号和设置，安装失败时自动回滚。环境检查不影响软件更新，Claude 启动前仍需通过安全检查。")
                .font(.caption).foregroundColor(ClaudeTheme.muted)
            Text("系统守护组件如需升级，会另行提示。")
                .font(.caption2).foregroundColor(ClaudeTheme.muted)
        }
    }
}

struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("版本更新").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("检查版本后，由你确认更新并重启").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(vm.updateText.isEmpty ? "尚未检查" : vm.updateText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(height: 110)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))

                UpdateControls(vm: vm)
            }
            .padding(20)
        }
        .frame(width: 540, height: 420)
        .preferredColorScheme(.light)
    }

}

// MARK: - AI 交接提示词

struct AIPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 交接提示词").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("复制后粘贴给本地 AI，让它先读 AGENTS.md 再动手").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))

                HStack {
                    Button { copyPrompt() } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .preferredColorScheme(.light)
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        copied = true
    }
}

// MARK: - 公告页

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。硬性安全项失败即 Block-on-Fail；仅显式配置的非关键项可跳过或降级，skip 不表示通过。"),
        ("Kill-Switch 断网急停", "常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，将裸连窗口压缩到秒级。进程级急停，非防火墙级保证，边界详见 SECURITY.md。"),
        ("Pinned Routing 域名置顶路由", "目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。"),
        ("Session Isolation 会话隔离快照", "多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。"),
        ("Drift Self-Healing 配置漂移自愈", "针对系统时区漂移、代理组件升级导致的配置重置等常见问题，内置 Watchdog 周期性校验并自动回滚至基线状态，全程留痕、可审计。"),
        ("Anti-Tracking 反追踪卫生", "验证链接（Magic Link）闭环于受保护环境内打开；邮件追踪像素（Tracking Pixel）经由邮箱服务商代理层屏蔽；全程固定单一住宅出口，不产生 Geo 跳变。"),
    ]

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全防护体系公告").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("Security Architecture Bulletin").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(.callout)
                            .foregroundColor(ClaudeTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(idx + 1). \(s.0)").font(.callout.bold()).foregroundColor(ClaudeTheme.terracottaDeep)
                                Text(s.1).font(.caption).foregroundColor(ClaudeTheme.muted).lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ClaudeTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(.caption2)
                            .foregroundColor(ClaudeTheme.muted)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: 460, height: 620)
        .preferredColorScheme(.light)
    }
}


// MARK: - 快捷面板

private enum QuickPanelPage: String {
    case home = "快捷面板"
    case checks = "环境检查"
    case settings = "检查设置"
    case fingerprint = "设备体检"
    case client = "代理客户端"
    case update = "版本更新"
    case ai = "AI 配置"
    case about = "安全防护"
}

private enum QuickPanelAction: String, CaseIterable {
    case check, fix, settings, fingerprint, client, update

    var title: String {
        switch self {
        case .check: return "重新检查"
        case .fix: return "一键修复"
        case .settings: return "检查设置"
        case .fingerprint: return "设备体检"
        case .client: return "代理客户端"
        case .update: return "检查更新"
        }
    }

    var icon: String {
        switch self {
        case .check: return "arrow.clockwise"
        case .fix: return "wand.and.stars"
        case .settings: return "slider.horizontal.3"
        case .fingerprint: return "waveform.path.ecg"
        case .client: return "network"
        case .update: return "arrow.down.circle"
        }
    }

    var keywords: String {
        switch self {
        case .check: return "环境 安检 audit refresh"
        case .fix: return "故障 修复 fix repair"
        case .settings: return "设置 日志 诊断 代理 settings log"
        case .fingerprint: return "指纹 字体 GPU fingerprint"
        case .client: return "代理 节点 clash verge flclash shadowrocket sing-box surge proxy client"
        case .update: return "版本 update version"
        }
    }
}

struct QuickPanelView: View {
    @ObservedObject var vm: VM
    @ObservedObject var guardSettings: BodyguardSettings
    let onDismiss: () -> Void
    let shortcutSettings: AnyView
    @State private var page = QuickPanelPage.home
    @State private var query = ""
    @State private var copied = false
    @FocusState private var searchFocused: Bool

    init(vm: VM, onDismiss: @escaping () -> Void, shortcutSettings: AnyView = AnyView(EmptyView()),
         guardSettings: BodyguardSettings = .unavailable()) {
        self.vm = vm
        self.guardSettings = guardSettings
        self.onDismiss = onDismiss
        self.shortcutSettings = shortcutSettings
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingAccounts: [String] { accountsMatching(term) }
    private func accountsMatching(_ term: String) -> [String] {
        VM.accountLetters.filter { account in
            if term.isEmpty { return true }
            if term.count == 1 && "ABCD".localizedCaseInsensitiveContains(term) {
                return account.caseInsensitiveCompare(term) == .orderedSame
            }
            return "账号 \(account) account \(account)".localizedCaseInsensitiveContains(term)
        }
    }
    private var matchingActions: [QuickPanelAction] { actionsMatching(term) }
    private func actionsMatching(_ term: String) -> [QuickPanelAction] {
        QuickPanelAction.allCases.filter { term.isEmpty || ($0.title + " " + $0.keywords).localizedCaseInsensitiveContains(term) }
    }
    private var matchingChecks: [CheckRow] { checksMatching(term) }
    private func checksMatching(_ term: String) -> [CheckRow] {
        vm.rows.filter { term.isEmpty || ($0.name + " " + $0.detail).localizedCaseInsensitiveContains(term) }
    }
    private var summaryColor: Color {
        if vm.phase == .failed { return ClaudeTheme.error }
        if vm.isBusy { return ClaudeTheme.terracottaDeep }
        if vm.rows.contains(where: { $0.state == .warn }) { return ClaudeTheme.warning }
        if vm.rows.contains(where: { $0.state == .skip }) { return ClaudeTheme.muted }
        return vm.lastCheckSummary == "通过" ? ClaudeTheme.success : ClaudeTheme.muted
    }
    private var summaryIcon: String {
        if vm.phase == .failed { return "exclamationmark.shield.fill" }
        if vm.isBusy { return "arrow.triangle.2.circlepath" }
        if vm.rows.contains(where: { $0.state == .warn }) { return "exclamationmark.triangle.fill" }
        if vm.rows.contains(where: { $0.state == .skip }) { return "minus.circle" }
        return vm.lastCheckSummary == "通过" ? "checkmark.shield.fill" : "clock"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().overlay(ClaudeTheme.cardBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if page == .home { homeContent }
                    else { detailContent }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(guardSettings.isApplying)
            footer
        }
        .frame(width: 760, height: 560)
        .background(ClaudeTheme.bgTop)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(ClaudeTheme.cardBorder, lineWidth: 1))
        .preferredColorScheme(.light)
        .onAppear {
            searchFocused = true
            consumeNavigationRequest()
        }
        .onChange(of: vm.showSettingsSheet) { _ in consumeNavigationRequest() }
        .onChange(of: vm.showUpdateSheet) { _ in consumeNavigationRequest() }
        .onChange(of: page) { _ in copied = false }
        .onExitCommand {
            if page == .home { onDismiss() }
            else { show(.home) }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 14) {
            if page == .home {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(ClaudeTheme.muted)
                    .frame(width: 26, height: 32)
                    .accessibilityHidden(true)
            } else {
                Button { show(.home) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(ClaudeTheme.muted)
                        .frame(width: 26, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回快捷面板")
            }
            if page == .home {
                TextField("搜索账号、检查或操作…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 23, weight: .regular))
                    .focused($searchFocused)
                    .onSubmit { performSearchResult(for: query) }
                    .accessibilityLabel("搜索账号、检查或操作")
            } else {
                Text(page.rawValue)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(ClaudeTheme.ink)
                Spacer()
            }
            Button(action: onDismiss) {
                Text("esc").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ClaudeTheme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(ClaudeTheme.iconWell)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("收起快捷面板")
            .accessibilityLabel("收起快捷面板")
        }
        .padding(.horizontal, 25).padding(.vertical, 20)
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            summaryCard
            if !vm.banner.isEmpty || !vm.note.isEmpty { operationMessage }
            if vm.coreMissing { missingCore }
            if !matchingAccounts.isEmpty {
                sectionHeading("切换账号", detail: "每次切换前重新完成安全检查")
                HStack(spacing: 12) {
                    ForEach(matchingAccounts, id: \.self) { account in accountButton(account) }
                }
            }
            if !matchingActions.isEmpty {
                sectionHeading(term.isEmpty ? "常用操作" : "匹配操作", detail: "")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(matchingActions, id: \.self) { action in actionButton(action) }
                }
            }
            if term.isEmpty {
                Button { show(.checks) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet.clipboard").foregroundColor(ClaudeTheme.terracottaDeep)
                        Text("查看 14 项检查").foregroundColor(ClaudeTheme.ink)
                        Spacer()
                        checkDots
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(14)
                    .background(ClaudeTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))
                }
                .buttonStyle(.plain)
            } else if !matchingChecks.isEmpty {
                sectionHeading("匹配检查", detail: "\(matchingChecks.count) 项")
                checksGrid(matchingChecks)
            }
            if !term.isEmpty && matchingAccounts.isEmpty && matchingActions.isEmpty && matchingChecks.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.title2)
                    Text("没有找到“\(term)”").font(.callout)
                    Text("试试账号 A、DNS、设置或更新").font(.caption)
                }
                .foregroundColor(ClaudeTheme.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(summaryColor.opacity(0.1))
                if vm.isBusy { ProgressView().scaleEffect(0.8) }
                else { Image(systemName: summaryIcon).font(.system(size: 24, weight: .regular)).foregroundColor(summaryColor) }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Claude 切换器").font(.system(size: 17, weight: .semibold, design: .serif))
                    Text("账号 \(vm.current)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(ClaudeTheme.terracottaTint).clipShape(Capsule())
                        .foregroundColor(ClaudeTheme.terracottaDeep)
                }
                Text("最近检查 · \(vm.lastCheckSummary)")
                    .font(.system(size: 12)).foregroundColor(summaryColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(vm.rows.filter { $0.state == .ok }.count) / 14")
                    .font(.system(size: 23, weight: .light, design: .rounded))
                    .monospacedDigit().foregroundColor(ClaudeTheme.ink)
                Text(checkCountText).font(.system(size: 10)).foregroundColor(ClaudeTheme.muted)
            }
        }
        .foregroundColor(ClaudeTheme.ink)
    }

    private var checkCountText: String {
        let warnings = vm.rows.filter { $0.state == .warn }.count
        let skipped = vm.rows.filter { $0.state == .skip }.count
        let failures = vm.rows.filter { $0.state == .fail }.count
        let pending = vm.rows.filter { $0.state == .pending }.count
        if pending == vm.rows.count { return "等待检查" }
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) 项待检查") }
        if failures > 0 { parts.append("\(failures) 项失败") }
        if warnings > 0 { parts.append("\(warnings) 项警告") }
        if skipped > 0 { parts.append("\(skipped) 项跳过") }
        return parts.isEmpty ? "全部检查通过" : parts.joined(separator: " · ")
    }

    private var checkDots: some View {
        HStack(spacing: 4) {
            ForEach(vm.rows) { row in
                Circle().fill(color(row.state)).frame(width: 5, height: 5)
                    .help("\(row.name)：\(statusText(row.state))")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("14 项检查，\(checkCountText)")
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(ClaudeTheme.ink)
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundColor(ClaudeTheme.muted)
        }
        .padding(.bottom, -10)
    }

    private func accountButton(_ account: String) -> some View {
        let active = vm.current == account
        return Button {
            guard !guardSettings.isApplying else { return }
            vm.switchTo(account)
        } label: {
            HStack(spacing: 11) {
                Text(account).font(.system(size: 22, weight: .medium, design: .rounded))
                    .frame(width: 40, height: 43)
                    .background(active ? Color.white.opacity(0.17) : ClaudeTheme.iconWell)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text("账号 \(account)").font(.system(size: 13, weight: .semibold))
                    Text(accountSubtitle(account))
                        .font(.system(size: 10)).lineLimit(1)
                        .foregroundColor(active ? Color.white.opacity(0.85) : ClaudeTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(active ? .white : ClaudeTheme.ink)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(active ? ClaudeTheme.terracottaDeep : ClaudeTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? Color.clear : ClaudeTheme.cardBorder))
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy || vm.coreMissing)
        .accessibilityLabel("账号 \(account)，\(accountSubtitle(account))，重新检查后切换")
        .help("完成 14 项审计后\(active ? "启动当前账号" : "切换至账号 " + account)")
    }

    private func accountSubtitle(_ account: String) -> String {
        if vm.current == account { return "当前使用" }
        if let stamp = vm.stamps[account] { return "已建档 · \(stamp.size)" }
        return vm.archived.contains(account) ? "已建档" : "首次登录"
    }

    private func actionButton(_ action: QuickPanelAction) -> some View {
        Button { perform(action) } label: {
            VStack(spacing: 9) {
                Image(systemName: action.icon)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(ClaudeTheme.terracottaDeep)
                    .frame(width: 43, height: 43)
                    .background(ClaudeTheme.terracottaTint)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(action.title).font(.system(size: 11)).foregroundColor(ClaudeTheme.ink)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actionNeedsIdle(action) && vm.isBusy)
    }

    private func actionNeedsIdle(_ action: QuickPanelAction) -> Bool {
        action == .check || action == .fix || action == .fingerprint
    }

    private func perform(_ action: QuickPanelAction) {
        guard !guardSettings.isApplying else { return }
        switch action {
        case .check: vm.refresh()
        case .fix: vm.fixAll()
        case .settings: show(.settings)
        case .fingerprint: show(.fingerprint); vm.inspectFingerprint()
        case .client: show(.client)
        case .update: show(.update); vm.checkUpdate()
        }
    }

    func performSearchResult(for query: String) {
        guard !guardSettings.isApplying else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if let account = accountsMatching(term).first { vm.switchTo(account) }
        else if let action = actionsMatching(term).first { perform(action) }
        else if !checksMatching(term).isEmpty { show(.checks) }
    }

    private func show(_ destination: QuickPanelPage) {
        page = destination
        query = ""
        searchFocused = destination == .home
        if destination == .settings { vm.loadCheckConfig(); guardSettings.refresh() }
    }

    private func consumeNavigationRequest() {
        if vm.showSettingsSheet {
            vm.showSettingsSheet = false
            show(.settings)
        }
        if vm.showUpdateSheet {
            vm.showUpdateSheet = false
            show(.update)
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch page {
        case .home: EmptyView()
        case .checks:
            summaryCard
            if !vm.banner.isEmpty || !vm.note.isEmpty { operationMessage }
            checksGrid(vm.rows)
            HStack {
                Text("灰色跳过项不计入通过数量").font(.caption).foregroundColor(ClaudeTheme.muted)
                Spacer()
                Button("重新检查") { vm.refresh() }.disabled(vm.isBusy)
                Button("一键修复") { vm.fixAll() }.disabled(vm.isBusy)
            }
        case .settings: settingsContent
        case .fingerprint:
            detailIntro("设备指纹体检", subtitle: "字体、GPU 与虚拟机特征；Canvas / WebGL 使用 Web 检测页")
            outputBox(vm.fingerprint.isEmpty ? "尚未体检" : vm.fingerprint)
            Button("重新体检") { vm.inspectFingerprint() }.disabled(vm.isBusy)
        case .client:
            detailIntro("选择代理客户端", subtitle: "切换后重新执行环境审计；不会自动安装或启动代理客户端")
            VStack(spacing: 10) {
                ForEach(VM.clientChoices, id: \.key) { choice in
                    Button { vm.setClient(choice.key) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "network").foregroundColor(ClaudeTheme.terracottaDeep)
                            Text(choice.label).font(.system(size: 13, weight: .medium)).foregroundColor(ClaudeTheme.ink)
                            Spacer()
                            if vm.currentClient == choice.key {
                                Label("当前", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11)).foregroundColor(ClaudeTheme.success)
                            }
                        }
                        .padding(13).background(ClaudeTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ClaudeTheme.cardBorder))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy || vm.isSwitchingClient || vm.coreMissing)
                }
            }
            if !vm.banner.isEmpty { operationMessage }
        case .update:
            detailIntro("检查新版本", subtitle: "检查版本后，由你确认更新 App 与核心并重启")
            outputBox(vm.updateText.isEmpty ? "尚未检查" : vm.updateText)
            UpdateControls(vm: vm)
        case .ai:
            detailIntro("交给本地 AI 配置", subtitle: "复制提示词，按仓库 AGENTS.md 安装与排障")
            outputBox(vm.aiPrompt)
            Button(copied ? "已复制提示词" : "复制提示词") { copy(vm.aiPrompt) }
        case .about:
            detailIntro("安全防护", subtitle: "14 项环境审计与独立守护进程协同工作")
            ForEach(Array(NoticeView().sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.0).font(.system(size: 13, weight: .semibold)).foregroundColor(ClaudeTheme.ink)
                    Text(section.1).font(.system(size: 11)).foregroundColor(ClaudeTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            detailIntro("检查偏好", subtitle: "只允许自定义以下六项非关键检查；硬性安全项始终执行")
            shortcutSettings
            BodyguardSettingsView(settings: guardSettings, operationsBusy: vm.isBusy || vm.settingsBusy)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 13) {
                ForEach(VM.optionalChecks, id: \.key) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { !vm.disabledChecks.contains(item.key) },
                        set: { enabled in
                            if enabled { vm.disabledChecks.remove(item.key) }
                            else { vm.disabledChecks.insert(item.key) }
                        }
                    ))
                    .toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 12))
                }
            }
            .padding(16).background(ClaudeTheme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(vm.settingsBusy)
            VStack(alignment: .leading, spacing: 13) {
                Toggle("将上述非关键项的失败降为警告", isOn: $vm.allowOptionalFailures)
                Toggle("记录脱敏客户端日志", isOn: $vm.loggingEnabled)
            }
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            .disabled(vm.settingsBusy)
            HStack {
                Text("代理客户端").font(.system(size: 12))
                Spacer()
                Picker("代理客户端", selection: Binding(get: { vm.currentClient }, set: { vm.setClient($0) })) {
                    if vm.currentClient.isEmpty { Text("尚未读取").tag("") }
                    ForEach(VM.clientChoices, id: \.key) { choice in Text(choice.label).tag(choice.key) }
                }
                .labelsHidden().frame(width: 180).disabled(vm.isBusy || vm.isSwitchingClient)
            }
            if !vm.settingsMessage.isEmpty {
                Text(vm.settingsMessage).font(.caption).foregroundColor(ClaudeTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("恢复默认") { vm.restoreCheckDefaults() }.disabled(vm.settingsBusy)
                Button("导出诊断…") { vm.exportDiagnostics() }.disabled(vm.settingsBusy)
                Spacer()
                if vm.settingsBusy { ProgressView().scaleEffect(0.65).frame(width: 18) }
                Button("保存并重新检查") { vm.saveCheckConfig() }
                    .buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
                    .disabled(vm.settingsBusy || vm.isBusy)
            }
        }
        .foregroundColor(ClaudeTheme.ink)
    }

    private func detailIntro(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundColor(ClaudeTheme.ink)
            Text(subtitle).font(.system(size: 11)).foregroundColor(ClaudeTheme.muted)
        }
    }

    private func outputBox(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced))
            .foregroundColor(ClaudeTheme.ink).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(ClaudeTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))
    }

    private func checksGrid(_ rows: [CheckRow]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 9) {
            ForEach(rows) { row in
                HStack(spacing: 9) {
                    Image(systemName: row.icon).font(.system(size: 12)).foregroundColor(ClaudeTheme.muted)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(row.name).font(.system(size: 11, weight: .medium)).foregroundColor(ClaudeTheme.ink)
                            Spacer(minLength: 0)
                            Text(statusText(row.state)).font(.system(size: 9, weight: .medium)).foregroundColor(color(row.state))
                        }
                        Text(row.detail.isEmpty ? "等待检查" : row.detail)
                            .font(.system(size: 10)).foregroundColor(ClaudeTheme.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Image(systemName: stateSymbol(row.state)).font(.system(size: 12)).foregroundColor(color(row.state))
                }
                .padding(10).background(ClaudeTheme.card).clipShape(RoundedRectangle(cornerRadius: 10))
                .help(row.detail)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var operationMessage: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !vm.banner.isEmpty { Text(vm.banner).font(.system(size: 12, weight: .medium)) }
            if !vm.note.isEmpty { Text(vm.note).font(.system(size: 11)) }
        }
        .foregroundColor(vm.phase == .failed ? ClaudeTheme.error : ClaudeTheme.terracottaDeep)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(ClaudeTheme.terracottaTint).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var missingCore: some View {
        HStack {
            Text("安装核心后即可执行检查与账号切换").font(.system(size: 12)).foregroundColor(ClaudeTheme.muted)
            Spacer()
            Link("安装说明 ↗", destination: URL(string: "https://github.com/chenchao19934/claude-switcher#安装")!)
                .font(.system(size: 12)).foregroundColor(ClaudeTheme.terracottaDeep)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("硬性安全项必须通过 · 灰色表示已跳过").font(.system(size: 10))
            Spacer()
            Button("AI 配置") { show(.ai) }
                .buttonStyle(.plain).font(.system(size: 10))
            Button { show(.about) } label: {
                Image(systemName: "info.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain).help("安全防护说明").accessibilityLabel("安全防护说明")
            if page != .home {
                Button("返回首页") { show(.home) }.buttonStyle(.plain).font(.system(size: 10))
            }
        }
        .foregroundColor(ClaudeTheme.muted)
        .padding(.horizontal, 24).padding(.vertical, 13)
        .background(ClaudeTheme.iconWell.opacity(0.7))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func color(_ state: RowState) -> Color {
        switch state {
        case .pending, .skip: return ClaudeTheme.muted
        case .ok: return ClaudeTheme.success
        case .warn: return ClaudeTheme.warning
        case .fail: return ClaudeTheme.error
        }
    }

    private func statusText(_ state: RowState) -> String {
        switch state {
        case .pending: return "待检查"
        case .ok: return "通过"
        case .warn: return "警告"
        case .fail: return "失败"
        case .skip: return "已跳过"
        }
    }

    private func stateSymbol(_ state: RowState) -> String {
        switch state {
        case .pending: return "clock"
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .skip: return "minus.circle"
        }
    }
}

// MARK: - 后台保镖巡检设置

struct BodyguardIntervalStatus: Decodable, Equatable {
    let interval: Int
    let throttleInterval: Int
    let registered: Bool
    let activeInterval: Int?

    var verifiedInterval: Int? {
        guard registered, (2...10).contains(interval), interval == throttleInterval,
              activeInterval == interval else { return nil }
        return interval
    }

    static func decode(_ text: String) -> BodyguardIntervalStatus? {
        guard let data = text.data(using: .utf8), data.count <= 4096,
              let status = try? JSONDecoder().decode(Self.self, from: data),
              (2...10).contains(status.interval), (2...10).contains(status.throttleInterval),
              status.activeInterval.map({ (2...10).contains($0) }) ?? true else { return nil }
        return status
    }
}

struct BodyguardCommandResult {
    let output: String
    let succeeded: Bool
    var cancelled = false
}

final class BodyguardSettings: ObservableObject {
    @Published private(set) var current: BodyguardIntervalStatus?
    @Published var selectedInterval = 10
    @Published private(set) var isBusy = false
    @Published private(set) var isApplying = false
    @Published private(set) var message = ""
    let isDemo: Bool
    var canStartApplication: () -> Bool = { true }
    private let readStatus: () -> BodyguardCommandResult
    private let writeInterval: (Int) -> BodyguardCommandResult
    private static let helper = "/Library/Application Support/claude-switcher/bodyguard-settings.py"

    init(isDemo: Bool = false, readStatus: @escaping () -> BodyguardCommandResult,
         writeInterval: @escaping (Int) -> BodyguardCommandResult) {
        self.isDemo = isDemo
        self.readStatus = readStatus
        self.writeInterval = writeInterval
    }

    static func unavailable() -> BodyguardSettings {
        BodyguardSettings(readStatus: { BodyguardCommandResult(output: "", succeeded: false) },
                          writeInterval: { _ in BodyguardCommandResult(output: "", succeeded: false) })
    }

    // 固定 root helper，管理员命令中唯一的可变输入是已校验的整数。
    static func live() -> BodyguardSettings {
        BodyguardSettings(readStatus: {
            guard helperIsTrusted() else { return BodyguardCommandResult(output: "", succeeded: false) }
            return run(executable: "/usr/bin/python3", arguments: ["-I", "-B", helper, "status"], timeout: 15)
        }, writeInterval: { interval in
            guard (2...10).contains(interval), helperIsTrusted() else {
                return BodyguardCommandResult(output: "", succeeded: false)
            }
            let command = "/usr/bin/python3 -I -B '\(helper)' apply \(interval)"
            let source = "do shell script \"\(command)\" with administrator privileges"
            // 授权等待不占用事务超时，避免在 root 重载/回滚中途强杀父进程。
            return run(executable: "/usr/bin/osascript", arguments: ["-e", source], timeout: nil)
        })
    }

    static func demo(core: String) -> BodyguardSettings {
        BodyguardSettings(isDemo: true, readStatus: {
            run(executable: "/bin/bash", arguments: [core, "get-bodyguard-interval"], timeout: 5)
        }, writeInterval: { interval in
            guard (2...10).contains(interval) else { return BodyguardCommandResult(output: "", succeeded: false) }
            return run(executable: "/bin/bash", arguments: [core, "set-bodyguard-interval", String(interval)], timeout: 5)
        })
    }

    var canApply: Bool {
        guard !isBusy, (2...10).contains(selectedInterval), let current = current, current.registered else { return false }
        return current.verifiedInterval != selectedInterval
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        message = "正在读取后台配置…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.readStatus()
            DispatchQueue.main.async {
                self.isBusy = false
                guard result.succeeded, let status = BodyguardIntervalStatus.decode(result.output) else {
                    self.current = nil
                    self.message = "无法确认后台周期。配置组件缺失或权限不可信时，需重新运行安装器；未修改系统设置。"
                    return
                }
                self.current = status
                self.selectedInterval = status.interval
                if !status.registered { self.message = "保镖尚未注册，请重新运行安装器；此处不会自动安装服务。" }
                else if status.verifiedInterval == nil { self.message = "磁盘配置与当前调度未确认一致，可重新授权应用后核对。" }
                else { self.message = self.isDemo ? "隔离演示：只更新仓库内假数据。" : "已核对系统调度；实际触发仍受睡眠、任务耗时等影响。" }
            }
        }
    }

    func apply() {
        guard !isBusy else { return }
        guard (2...10).contains(selectedInterval) else {
            message = "巡检周期仅支持 2–10 秒，不能停用或延长现有保护基线。"
            return
        }
        guard canApply, canStartApplication() else {
            message = "请等待当前操作完成，并先读取已注册的保镖状态。"
            return
        }
        let requested = selectedInterval
        isBusy = true; isApplying = true
        message = isDemo ? "正在模拟应用…" : "请完成系统管理员授权，正在应用并核对后台调度…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.writeInterval(requested)
            DispatchQueue.main.async {
                self.isBusy = false; self.isApplying = false
                if result.cancelled {
                    self.message = "已取消管理员授权，保留原后台周期。"
                } else if result.succeeded, let status = BodyguardIntervalStatus.decode(result.output),
                          status.verifiedInterval == requested {
                    self.current = status
                    self.selectedInterval = requested
                    self.message = self.isDemo ? "模拟周期已更新为 \(requested) 秒；真实服务未改动。" : "已核对后台调度为 \(requested) 秒；无需保持面板打开。"
                } else {
                    self.current = nil
                    self.message = "未确认配置成功；请刷新核对后台实际状态。若重载失败，配置组件会尝试恢复旧配置；无法恢复时请重跑安装器。"
                }
            }
        }
    }

    private static func helperIsTrusted() -> Bool {
        for path in ["/Library", "/Library/Application Support"] {
            var attributes = stat()
            guard !FileManager.default.isWritableFile(atPath: path),
                  lstat(path, &attributes) == 0, attributes.st_uid == 0,
                  attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o022 == 0 else { return false }
        }
        for (path, expectedType, expectedMode) in [("/Library/Application Support/claude-switcher", mode_t(S_IFDIR), mode_t(0o755)),
                                                   (helper, mode_t(S_IFREG), mode_t(0o755))] {
            var attributes = stat()
            guard !FileManager.default.isWritableFile(atPath: path),
                  lstat(path, &attributes) == 0, attributes.st_uid == 0, attributes.st_gid == 0,
                  attributes.st_mode & S_IFMT == expectedType, attributes.st_mode & 0o7777 == expectedMode else { return false }
        }
        return true
    }

    private static func run(executable: String, arguments: [String], timeout: TimeInterval?) -> BodyguardCommandResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bodyguard-settings-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: file) else { return BodyguardCommandResult(output: "", succeeded: false) }
        defer { try? output.close(); try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return BodyguardCommandResult(output: "", succeeded: false) }
        let deadline = ProcessDeadline()
        let watchdog = timeout.map { timeout -> DispatchWorkItem in
            let item = DispatchWorkItem { deadline.expire(process) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            return item
        }
        process.waitUntilExit()
        watchdog?.cancel()
        let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return BodyguardCommandResult(output: text, succeeded: !deadline.timedOut && process.terminationStatus == 0,
                                      cancelled: text.contains("(-128)"))
    }
}

import SwiftUI

struct BodyguardSettingsView: View {
    @ObservedObject var settings: BodyguardSettings
    let operationsBusy: Bool

    private var busy: Bool { settings.isBusy || settings.isApplying || operationsBusy }
    private var verifiedInterval: Int? { settings.current?.verifiedInterval }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(ClaudeTheme.terracottaDeep)
                    .frame(width: 30, height: 30)
                    .background(ClaudeTheme.terracottaTint)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("后台保镖巡检")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ClaudeTheme.ink)
                        if settings.isDemo {
                            Text("演示")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(ClaudeTheme.terracottaDeep)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(ClaudeTheme.terracottaTint)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text(settings.isDemo ? "模拟生效周期" : "当前实际周期")
                        Text(verifiedInterval.map { "\($0) 秒" } ?? "未确认")
                            .fontWeight(.medium)
                            .foregroundColor(verifiedInterval == nil ? ClaudeTheme.warning : ClaudeTheme.ink)
                        if verifiedInterval == nil, let status = settings.current {
                            Text("· 配置为 \(status.interval) 秒")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(ClaudeTheme.muted)
                }
                Spacer(minLength: 0)
                if settings.isBusy || settings.isApplying {
                    ProgressView().controlSize(.small).frame(width: 18, height: 25)
                }
            }

            HStack(spacing: 12) {
                Text("巡检间隔")
                    .font(.system(size: 12))
                    .foregroundColor(ClaudeTheme.ink)
                Text("2–10 秒 · 默认 10 秒")
                    .font(.system(size: 10))
                    .foregroundColor(ClaudeTheme.muted)
                Spacer(minLength: 4)
                Stepper(value: $settings.selectedInterval, in: 2...10, step: 1) {
                    Text("\(settings.selectedInterval) 秒")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(ClaudeTheme.ink)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .fixedSize()
                .disabled(busy)
                .accessibilityLabel("后台保镖巡检间隔，2 到 10 秒")
            }

            Text("只检查代理内核与 TUN，退出 App 后仍独立运行；不执行完整 14 项网络审计。")
                .font(.system(size: 10))
                .foregroundColor(ClaudeTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("刷新状态") { settings.refresh() }
                    .controlSize(.small)
                    .disabled(busy)
                Spacer(minLength: 4)
                Text(settings.isDemo ? "仅更新演示数据" : "需要管理员授权")
                    .font(.system(size: 10))
                    .foregroundColor(ClaudeTheme.muted)
                Button(settings.isApplying ? "正在应用…" : (settings.isDemo ? "模拟应用" : "授权并应用")) {
                    settings.apply()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(ClaudeTheme.terracottaDeep)
                .disabled(busy || !settings.canApply)
            }

            if !settings.message.isEmpty {
                Text(settings.message)
                    .font(.system(size: 10))
                    .foregroundColor(ClaudeTheme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("后台保镖巡检设置")
    }
}


// MARK: - 呼出快捷键与展示偏好

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let standard = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    var isValid: Bool {
        keyCode <= 126 && keyCode != UInt32(kVK_Escape) &&
        modifiers & ~Self.modifierMask == 0 && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    var label: String {
        var text = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { text += symbol }
        }
        let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",65:".",67:"*",69:"+",75:"/",76:"Enter",78:"−",81:"=",82:"0",83:"1",84:"2",85:"3",86:"4",87:"5",88:"6",89:"7",91:"8",92:"9",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"Help",115:"Home",116:"Page Up",117:"⌦",118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return text + (names[keyCode] ?? "Key \(keyCode)")
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        for (native, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] {
            if event.modifierFlags.contains(native) { flags |= UInt32(carbon) }
        }
        modifiers = flags
    }
}

final class AppPreferences: ObservableObject {
    @Published private(set) var shortcut: GlobalShortcut?
    @Published var shortcutMessage = ""
    @Published var isRecordingShortcut = false
    var requestShortcut: ((GlobalShortcut?) -> Void)?
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if defaults?.object(forKey: "quickPanel.shortcutEnabled") != nil,
           defaults?.bool(forKey: "quickPanel.shortcutEnabled") == false {
            shortcut = nil
        } else if let data = defaults?.data(forKey: "quickPanel.shortcut"),
                  let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    func commit(_ value: GlobalShortcut?) {
        shortcut = value
        shortcutMessage = value.map { "已保存：\($0.label)" } ?? "快捷键已停用，仍可点击菜单栏呼出"
        defaults?.set(value != nil, forKey: "quickPanel.shortcutEnabled")
        if let value = value, let data = try? JSONEncoder().encode(value) {
            defaults?.set(data, forKey: "quickPanel.shortcut")
        } else {
            defaults?.removeObject(forKey: "quickPanel.shortcut")
        }
    }
}

final class GlobalHotKey {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var current: GlobalShortcut?
    var onPress: ((TimeInterval) -> Void)?

    func replace(with shortcut: GlobalShortcut?) -> OSStatus {
        if shortcut == current { return noErr }
        guard let shortcut = shortcut else {
            if let registration = registration { UnregisterEventHotKey(registration) }
            registration = nil; current = nil
            return noErr
        }
        guard shortcut.isValid else { return OSStatus(paramErr) }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x43535754, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().onPress?(GetEventTime(event))
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return result }
        }
        // 新组合注册成功才撤销旧组合，冲突时保留原来的可用入口。
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x43535754, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &replacement)
        guard result == noErr else { return result }
        if let registration = registration { UnregisterEventHotKey(registration) }
        registration = replacement; current = shortcut
        return noErr
    }

    deinit {
        if let registration = registration { UnregisterEventHotKey(registration) }
        if let handler = handler { RemoveEventHandler(handler) }
    }
}

struct ShortcutPressGate {
    private var lastTimestamp: TimeInterval?
    mutating func accepts(timestamp: TimeInterval, isRepeat: Bool = false) -> Bool {
        guard timestamp.isFinite, timestamp >= 0, !isRepeat else { return false }
        if let last = lastTimestamp, timestamp - last < 0.15 { return false }
        lastTimestamp = timestamp
        return true
    }
}

private final class ShortcutCaptureButton: NSButton {
    var capture: ((GlobalShortcut?) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    var savedTitle = ""
    private var recording = false
    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        recording = true
        title = "按下新组合…"
        recordingChanged?(true)
        window?.makeFirstResponder(self)
    }

    private func finish() {
        recording = false
        title = savedTitle
        recordingChanged?(false)
    }

    override func resignFirstResponder() -> Bool {
        finish()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { finish(); return }
        if event.keyCode == UInt16(kVK_Delete) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            finish(); capture?(nil); return
        }
        let shortcut = GlobalShortcut(event: event)
        finish()
        capture?(shortcut)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var preferences: AppPreferences
    func makeNSView(context: Context) -> ShortcutCaptureButton {
        let button = ShortcutCaptureButton(title: "", target: nil, action: #selector(ShortcutCaptureButton.beginRecording))
        button.target = button
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("录制呼出快捷键")
        return button
    }
    func updateNSView(_ button: ShortcutCaptureButton, context: Context) {
        button.savedTitle = preferences.shortcut?.label ?? "点击录制快捷键"
        if !preferences.isRecordingShortcut { button.title = button.savedTitle }
        button.capture = { preferences.requestShortcut?($0) }
        button.recordingChanged = { preferences.isRecordingShortcut = $0 }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("快捷呼出").font(.system(size: 13, weight: .semibold))
                Spacer()
                ShortcutRecorder(preferences: preferences).frame(width: 170, height: 28)
                Button("恢复默认") { preferences.requestShortcut?(.standard) }
                    .disabled(preferences.isRecordingShortcut)
                Button("停用") { preferences.requestShortcut?(nil) }
                    .disabled(preferences.isRecordingShortcut || preferences.shortcut == nil)
            }
            Text("点击录制，按下含 ⌃ / ⌥ / ⌘ 的组合；Esc 取消，Delete 停用。更改立即保存。")
                .font(.system(size: 11)).foregroundColor(ClaudeTheme.muted)
            if !preferences.shortcutMessage.isEmpty {
                Text(preferences.shortcutMessage).font(.system(size: 11)).foregroundColor(ClaudeTheme.terracottaDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).background(ClaudeTheme.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 菜单栏与 Widget 的脱敏状态

struct WidgetStatusSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let currentAccount: String
    let status: String
    let checkedAt: Double
    let passed: Int
    let warning: Int
    let failed: Int
    let skipped: Int
    let pending: Int

    static func capture(_ vm: VM, checkedAt: Double) -> WidgetStatusSnapshot {
        let status: String
        switch vm.phase {
        case .checking: status = "checking"
        case .ready: status = "ready"
        case .failed: status = "failed"
        case .fixing: status = "fixing"
        case .switching: status = "switching"
        case .done: status = "done"
        }
        let current = VM.accountLetters.contains(vm.current) ? vm.current : "none"
        return WidgetStatusSnapshot(schemaVersion: 1, currentAccount: current, status: status,
            checkedAt: checkedAt, passed: vm.rows.filter { $0.state == .ok }.count,
            warning: vm.rows.filter { $0.state == .warn }.count, failed: vm.rows.filter { $0.state == .fail }.count,
            skipped: vm.rows.filter { $0.state == .skip }.count, pending: vm.rows.filter { $0.state == .pending }.count)
    }

    var menuSummary: String {
        if status == "checking" { return "检查中" }
        if status == "fixing" { return "修复中" }
        if status == "switching" { return "切换中" }
        if status == "failed" || failed > 0 { return "未通过" }
        if checkedAt == 0 || pending > 0 || passed + warning + failed + skipped != 14 { return "待检查" }
        if warning > 0 { return "有警告" }
        if skipped > 0 { return "含跳过" }
        return "通过"
    }

    var symbol: String {
        switch menuSummary {
        case "未通过": return "exclamationmark.shield"
        case "有警告": return "exclamationmark.triangle"
        case "通过": return "checkmark.shield"
        case "含跳过": return "minus.circle"
        case "检查中", "修复中", "切换中": return "arrow.triangle.2.circlepath"
        default: return "shield.lefthalf.filled"
        }
    }
}

final class WidgetStatusPublisher {
    private let defaults: UserDefaults?
    private var lastData: Data?
    init(appGroup: String?) {
        if let appGroup = appGroup, !appGroup.isEmpty { defaults = UserDefaults(suiteName: appGroup) }
        else { defaults = nil }
    }
    func publish(_ snapshot: WidgetStatusSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let defaults = defaults, let data = try? encoder.encode(snapshot), data != lastData else { return }
        defaults.set(data, forKey: "statusSnapshot")
        lastData = data
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeSwitcherStatusWidget")
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let vm: VM
    let preferences: AppPreferences
    let guardSettings: BodyguardSettings
    private(set) var mainWindow: NSWindow?
    private(set) var statusItem: NSStatusItem?
    private let hotKey = GlobalHotKey()
    private let enableSystemIntegration: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var widgetPublisher: WidgetStatusPublisher?
    private var checkedAt: Double = 0
    private var auditInFlight = false
    private var installedObservers = false
    private var localEventMonitor: Any?
    private var shortcutPressGate = ShortcutPressGate()

    override init() {
        vm = VM()
        preferences = AppPreferences(defaults: .standard)
        guardSettings = .live()
        enableSystemIntegration = true
        super.init()
        configurePreferences()
    }

    // 测试默认关闭系统快捷键与共享容器写入，且不保存真实用户偏好。
    init(vm: VM, preferences: AppPreferences = AppPreferences(), enableSystemIntegration: Bool = false,
         guardSettings: BodyguardSettings = .unavailable()) {
        self.vm = vm
        self.preferences = preferences
        self.guardSettings = guardSettings
        self.enableSystemIntegration = enableSystemIntegration
        super.init()
        configurePreferences()
    }

    private func configurePreferences() {
        vm.canMonitor = { [weak self] in
            guard let self = self else { return false }
            return !self.guardSettings.isApplying
        }
        guardSettings.$isApplying.sink { [weak self] applying in
            if applying { self?.vm.invalidateMonitorSample() }
        }.store(in: &subscriptions)
        guardSettings.canStartApplication = { [weak self] in
            guard let self = self else { return false }
            return !self.vm.isBusy && !self.vm.settingsBusy
        }
        preferences.requestShortcut = { [weak self] candidate in self?.setShortcut(candidate) }
        hotKey.onPress = { [weak self] timestamp in
            self?.handleShortcutPress(timestamp: timestamp)
        }
    }

    func setShortcut(_ candidate: GlobalShortcut?) {
        guard candidate?.isValid != false else {
            preferences.shortcutMessage = "请选择包含 Control、Option 或 Command 的有效组合"
            return
        }
        if enableSystemIntegration {
            let result = hotKey.replace(with: candidate)
            guard result == noErr else {
                preferences.shortcutMessage = "快捷键被系统或其他应用占用（\(result)），保留原设置；仍可点击菜单栏呼出"
                return
            }
        }
        preferences.commit(candidate)
        updateStatusItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        vm.onSwitchCompleted = { [weak self] in self?.hidePanel() }
        vm.onUpdateRestartReady = { NSApplication.shared.terminate(nil) }
        setupStatusItem()
        observeModel()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.mainWindow?.isKeyWindow == true,
                  !self.preferences.isRecordingShortcut,
                  NSApplication.shared.modalWindow == nil, self.mainWindow?.attachedSheet == nil else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.hidePanel()
                return nil
            }
            if self.preferences.shortcut == GlobalShortcut(event: event) {
                self.handleShortcutPress(timestamp: event.timestamp, isRepeat: event.isARepeat)
                return nil
            }
            return event
        }
        if enableSystemIntegration {
            widgetPublisher = WidgetStatusPublisher(appGroup: Bundle.main.object(forInfoDictionaryKey: "ClaudeSwitcherAppGroup") as? String)
            let result = hotKey.replace(with: preferences.shortcut)
            if result != noErr { preferences.shortcutMessage = "呼出快捷键注册失败（\(result)），请在检查设置中更换；菜单栏仍可使用" }
        }
        showMainWindow()
        vm.start()
        if let flag = CommandLine.arguments.firstIndex(of: "--update-token"),
           CommandLine.arguments.indices.contains(flag + 1) {
            vm.acknowledgeUpdate(token: CommandLine.arguments[flag + 1])
        }
    }

    private func observeModel() {
        guard !installedObservers else { return }
        installedObservers = true
        vm.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self = self else { return }
            if phase == .checking { self.auditInFlight = true }
            else if self.auditInFlight {
                self.checkedAt = Date().timeIntervalSince1970
                self.auditInFlight = false
            }
        }.store(in: &subscriptions)
        vm.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.updateStatusItem()
        }.store(in: &subscriptions)
        updateStatusItem()
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateStatusItem()
    }

    func updateStatusItem() {
        let snapshot = WidgetStatusSnapshot.capture(vm, checkedAt: checkedAt)
        if let button = statusItem?.button {
            let account = snapshot.currentAccount == "none" ? "—" : snapshot.currentAccount
            button.title = " \(account) · \(snapshot.menuSummary)"
            button.image = NSImage(systemSymbolName: snapshot.symbol, accessibilityDescription: "Claude 切换器")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let shortcut = preferences.shortcut?.label ?? "点击"
            button.toolTip = "Claude 切换器 · 最近检查：\(snapshot.menuSummary)\n\(shortcut) 呼出；右键显示菜单"
            button.setAccessibilityLabel("Claude 切换器，账号 \(account)，最近检查 \(snapshot.menuSummary)")
        }
        widgetPublisher?.publish(snapshot)
    }

    @objc private func statusClicked() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            func item(_ title: String, _ action: Selector, enabled: Bool = true) {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self; entry.isEnabled = enabled
                menu.addItem(entry)
            }
            item("呼出快捷面板", #selector(menuOpen))
            item("重新检查", #selector(menuRefresh), enabled: !vm.isBusy && !guardSettings.isApplying)
            item("检查设置与快捷键", #selector(menuSettings))
            item("检查更新", #selector(menuUpdate))
            menu.addItem(.separator())
            item("退出 Claude 切换器", #selector(menuQuit), enabled: vm.canQuit && !guardSettings.isApplying)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
        } else {
            togglePanel()
        }
    }

    func menuDidClose(_ menu: NSMenu) { statusItem?.menu = nil }
    @objc private func menuOpen() { showMainWindow() }
    func recheckFromMenu() {
        guard !guardSettings.isApplying else { return }
        vm.refresh(); showMainWindow()
    }
    @objc private func menuRefresh() { recheckFromMenu() }
    @objc private func menuSettings() { showMainWindow(); vm.showSettingsSheet = true }
    @objc private func menuUpdate() { showMainWindow(); vm.checkUpdate(); vm.showUpdateSheet = true }
    @objc private func menuQuit() { if vm.canQuit && !guardSettings.isApplying { NSApplication.shared.terminate(nil) } }

    func togglePanel() {
        if mainWindow?.isVisible == true { hidePanel() }
        else { showMainWindow() }
    }

    func handleShortcutPress(timestamp: TimeInterval, isRepeat: Bool = false) {
        guard !preferences.isRecordingShortcut, NSApplication.shared.modalWindow == nil,
              mainWindow?.attachedSheet == nil,
              !(mainWindow?.childWindows?.contains(where: { $0.isVisible }) ?? false),
              shortcutPressGate.accepts(timestamp: timestamp, isRepeat: isRepeat) else { return }
        togglePanel()
    }

    func hidePanel() { mainWindow?.orderOut(nil) }

    func showMainWindow() {
        vm.prepareToShow()
        vm.refreshAccountStatus()
        if mainWindow == nil {
            let panel = QuickAccessPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Claude 切换器"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: QuickPanelView(vm: vm,
                onDismiss: { [weak self] in self?.hidePanel() },
                shortcutSettings: AnyView(ShortcutSettingsView(preferences: preferences)),
                guardSettings: guardSettings))
            panel.delegate = self
            mainWindow = panel
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            mainWindow?.setFrameOrigin(NSPoint(x: frame.midX - 380, y: frame.midY - 230))
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var canAutoDismiss: Bool {
        guard !vm.isBusy, !vm.settingsBusy, !guardSettings.isBusy, !preferences.isRecordingShortcut,
              NSApplication.shared.modalWindow == nil, mainWindow?.attachedSheet == nil else { return false }
        return !(mainWindow?.childWindows?.contains(where: { $0.isVisible }) ?? false)
    }

    func dismissOnDeactivation() {
        if canAutoDismiss { hidePanel() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // 保存对话框与提示框会临时取走焦点，下一轮再判断模态状态。
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.mainWindow?.isKeyWindow != true else { return }
            self.dismissOnDeactivation()
        }
    }
    func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !NSApplication.shared.isActive else { return }
            self.dismissOnDeactivation()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePanel(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { vm.stopMonitoring() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vm.canQuit && !guardSettings.isApplying ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return false }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "claude-switcher" && $0.host == "panel" && ($0.path.isEmpty || $0.path == "/") && $0.query == nil }) {
            showMainWindow()
        }
    }

    deinit {
        if let localEventMonitor = localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let statusItem = statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

struct MenuBarContent: View {
    @ObservedObject var vm: VM
    let showWindow: () -> Void
    var canOperate: () -> Bool = { true }

    var body: some View {
        Text("Claude 切换器")
        Text("当前账号：\(vm.current)")
        Text("最近检查：\(vm.lastCheckSummary)")
        if vm.phase == .fixing { Text("正在修复…") }
        if vm.phase == .switching { Text("正在切换账号…") }
        Divider()
        Button("打开主窗口", action: showWindow)
            .keyboardShortcut("o")
        Button("重新检查") {
            guard canOperate() else { return }
            vm.refresh()
            showWindow()
        }
        .disabled(vm.isBusy || !canOperate())
        Button("检查更新") {
            showWindow()
            vm.checkUpdate()
            vm.showUpdateSheet = true
        }
        Button("检查设置") {
            showWindow()
            vm.showSettingsSheet = true
        }
        Button("导出诊断日志") { if canOperate() { vm.exportDiagnostics() } }
            .disabled(vm.settingsBusy)
        Divider()
        Button("退出 Claude 切换器") { if canOperate() { NSApplication.shared.terminate(nil) } }
            .keyboardShortcut("q")
            .disabled(!vm.canQuit)
            .onAppear { vm.refreshAccountStatus() }
    }
}

// 生产应用与 UI 测试共用完全相同的菜单和窗口管理。
struct SwitcherMenu: Scene {
    @ObservedObject var vm: VM
    @ObservedObject private var guardSettings: BodyguardSettings
    let controller: AppDelegate

    init(vm: VM, controller: AppDelegate) {
        self.vm = vm
        self.controller = controller
        guardSettings = controller.guardSettings
    }

    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(!vm.canQuit || guardSettings.isApplying)
            }
        }
    }
}

#if !CLAUDE_SWITCHER_TESTS
@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwitcherMenu(vm: appDelegate.vm, controller: appDelegate)
    }
}
#endif

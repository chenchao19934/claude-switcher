import Foundation
import SwiftUI
import WidgetKit

// 与主应用只共享脱敏摘要；扩展不读取核心、账号目录或网络。
struct StatusWidgetSnapshot: Codable {
    let schemaVersion: Int
    let currentAccount: String
    let status: String
    let checkedAt: Double
    let passed: Int
    let warning: Int
    let failed: Int
    let skipped: Int
    let pending: Int

    static func decode(_ data: Data, now: Date = Date()) -> StatusWidgetSnapshot? {
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "currentAccount", "status", "checkedAt",
                                      "passed", "warning", "failed", "skipped", "pending"]),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.schemaVersion == 1,
              ["A", "B", "C", "D", "none", "unknown", "?", "未知", "未初始化"].contains(snapshot.currentAccount),
              ["checking", "ready", "failed", "fixing", "switching", "done", "unknown"].contains(snapshot.status),
              snapshot.checkedAt.isFinite, snapshot.checkedAt >= 0,
              snapshot.checkedAt <= now.timeIntervalSince1970 + 60 else { return nil }
        let counts = [snapshot.passed, snapshot.warning, snapshot.failed, snapshot.skipped, snapshot.pending]
        guard counts.allSatisfy({ (0...14).contains($0) }), counts.reduce(0, +) == 14 else { return nil }
        return snapshot
    }

    func isStale(at date: Date) -> Bool {
        checkedAt > 0 && date.timeIntervalSince1970 - checkedAt >= 30 * 60
    }

    var accountLabel: String {
        ["A", "B", "C", "D"].contains(currentAccount) ? "账号 \(currentAccount)" : "尚无账号"
    }
}

struct StatusWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: StatusWidgetSnapshot?
    let configured: Bool
    var preview = false

    var headline: String {
        guard configured else { return "等待配置" }
        guard let snapshot = snapshot else { return "等待检查" }
        if snapshot.checkedAt == 0 { return "尚未检查" }
        if snapshot.status == "failed" || snapshot.failed > 0 {
            return snapshot.isStale(at: date) ? "未通过 · 结果已过期" : "检查未通过"
        }
        if snapshot.isStale(at: date) { return "结果已过期" }
        switch snapshot.status {
        case "checking": return "上次状态：检查中"
        case "fixing": return "上次状态：修复中"
        case "switching": return "上次状态：切换中"
        case "unknown": return "等待检查"
        default: break
        }
        if snapshot.pending > 0 { return "检查未完成" }
        if snapshot.warning > 0 { return "有警告" }
        if snapshot.skipped > 0 { return "通过 · 含跳过" }
        return "最近检查通过"
    }

    var resultTone: StatusWidgetTone {
        guard let snapshot = snapshot, snapshot.checkedAt > 0 else { return .muted }
        if snapshot.status == "failed" || snapshot.failed > 0 { return .failure }
        if snapshot.isStale(at: date) { return .muted }
        if ["checking", "fixing", "switching", "unknown"].contains(snapshot.status) || snapshot.pending > 0 {
            return .muted
        }
        if snapshot.warning > 0 { return .warning }
        return snapshot.skipped > 0 ? .muted : .success
    }
}

enum StatusWidgetTone: Equatable { case muted, failure, warning, success }

struct StatusWidgetProvider: TimelineProvider {
    static func timelineEntries(for current: StatusWidgetEntry) -> [StatusWidgetEntry] {
        guard current.configured, let snapshot = current.snapshot,
              snapshot.checkedAt.isFinite, snapshot.checkedAt > 0 else { return [current] }
        let expiration = snapshot.checkedAt + 30 * 60
        guard expiration.isFinite, expiration > current.date.timeIntervalSince1970 else { return [current] }
        // 提前安排过期视图；即使系统推迟重新读取共享状态，也不沿用旧的通过快照。
        let expired = StatusWidgetEntry(date: Date(timeIntervalSince1970: expiration),
                                        snapshot: snapshot, configured: current.configured, preview: current.preview)
        return [current, expired]
    }

    private func entry(at date: Date = Date()) -> StatusWidgetEntry {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ClaudeSwitcherAppGroup") as? String,
              !group.isEmpty, let defaults = UserDefaults(suiteName: group) else {
            return StatusWidgetEntry(date: date, snapshot: nil, configured: false)
        }
        let snapshot = defaults.data(forKey: "statusSnapshot").flatMap { StatusWidgetSnapshot.decode($0, now: date) }
        return StatusWidgetEntry(date: date, snapshot: snapshot, configured: true)
    }

    func placeholder(in context: Context) -> StatusWidgetEntry {
        StatusWidgetEntry(date: Date(), snapshot: nil, configured: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusWidgetEntry) -> Void) {
        if context.isPreview {
            let sample = StatusWidgetSnapshot(schemaVersion: 1, currentAccount: "A", status: "ready",
                                              checkedAt: Date().timeIntervalSince1970,
                                              passed: 13, warning: 1, failed: 0, skipped: 0, pending: 0)
            completion(StatusWidgetEntry(date: Date(), snapshot: sample, configured: true, preview: true))
        } else {
            completion(entry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusWidgetEntry>) -> Void) {
        let current = entry()
        // 系统决定实际刷新时机；主应用写入摘要后也会请求 reloadTimelines。
        let next = current.date.addingTimeInterval(15 * 60)
        completion(Timeline(entries: Self.timelineEntries(for: current), policy: .after(next)))
    }
}

private enum StatusWidgetPalette {
    static let ink = Color(red: 0.18, green: 0.16, blue: 0.15)
    static let muted = Color(red: 0.47, green: 0.44, blue: 0.40)
    static let accent = Color(red: 0.77, green: 0.38, blue: 0.27)
    static let green = Color(red: 0.18, green: 0.49, blue: 0.32)
    static let amber = Color(red: 0.72, green: 0.43, blue: 0.09)
    static let background = Color(red: 0.98, green: 0.97, blue: 0.94)
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusWidgetEntry

    private var resultColor: Color {
        switch entry.resultTone {
        case .muted: return StatusWidgetPalette.muted
        case .failure: return StatusWidgetPalette.accent
        case .warning: return StatusWidgetPalette.amber
        case .success: return StatusWidgetPalette.green
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").foregroundColor(StatusWidgetPalette.accent)
                Text("Claude 切换器").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if family == .systemMedium {
                    Image(systemName: "arrow.up.forward").font(.caption2).foregroundColor(StatusWidgetPalette.muted)
                }
            }
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.snapshot?.accountLabel ?? "尚无账号")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .privacySensitive()
                    Text(entry.headline).font(.system(size: 12, weight: .medium)).foregroundColor(resultColor)
                    if family == .systemSmall, let snapshot = entry.snapshot {
                        Text("\(snapshot.passed)/14 项通过")
                            .font(.system(size: 10)).foregroundColor(StatusWidgetPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if family == .systemMedium {
                    metrics
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview ? "预览 · 最近检查，非实时" : "最近检查，非实时")
                if let snapshot = entry.snapshot, snapshot.checkedAt > 0 {
                    HStack(spacing: 4) {
                        Text("更新于")
                        Text(Date(timeIntervalSince1970: snapshot.checkedAt), style: .time)
                    }
                } else {
                    Text(entry.configured ? "打开面板完成一次检查" : "使用带小组件的签名构建")
                }
            }
            .font(.system(size: 9))
            .foregroundColor(StatusWidgetPalette.muted)
        }
        .foregroundColor(StatusWidgetPalette.ink)
        .widgetURL(URL(string: "claude-switcher://panel"))
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.fixed(48)), GridItem(.fixed(48))], spacing: 10) {
            metric("通过", value: entry.snapshot?.passed, color: StatusWidgetPalette.green)
            metric("警告", value: entry.snapshot?.warning, color: StatusWidgetPalette.amber)
            metric("失败", value: entry.snapshot?.failed, color: StatusWidgetPalette.accent)
            metric("跳过", value: entry.snapshot?.skipped, color: StatusWidgetPalette.muted)
        }
        .frame(width: 106)
    }

    private func metric(_ label: String, value: Int?, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "—").font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 9))
        }
        .foregroundColor(color)
        .accessibilityLabel("\(label) \(value.map(String.init) ?? "未知") 项")
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            content.containerBackground(for: .widget) { StatusWidgetPalette.background }
        } else {
            content.padding(16).background(StatusWidgetPalette.background)
        }
    }
}

#if !STATUS_WIDGET_TESTS
@main
struct ClaudeSwitcherStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeSwitcherStatusWidget", provider: StatusWidgetProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude 状态")
        .description("查看当前账号和最近一次环境检查摘要。点击打开快捷面板；结果不是实时监控。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
#endif

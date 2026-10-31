import Foundation

private struct WidgetTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw WidgetTestFailure(description: message) }
}

private struct WidgetFixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    var valid: [String: Any] {
        ["schemaVersion": 1, "currentAccount": "A", "status": "ready",
         "checkedAt": now.timeIntervalSince1970, "passed": 13, "warning": 1,
         "failed": 0, "skipped": 0, "pending": 0]
    }

    func decode(_ object: [String: Any]) throws -> StatusWidgetSnapshot? {
        let data = try JSONSerialization.data(withJSONObject: object)
        return StatusWidgetSnapshot.decode(data, now: now)
    }

    func rejected(_ object: [String: Any], _ message: String) throws {
        let snapshot = try decode(object)
        try expect(snapshot == nil, message)
    }

    func required(_ object: [String: Any]) throws -> StatusWidgetSnapshot {
        guard let snapshot = try decode(object) else {
            throw WidgetTestFailure(description: "合法摘要被拒绝")
        }
        return snapshot
    }
}

@main
struct WidgetModelTests {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw WidgetTestFailure(description: "缺少 Widget 测试场景")
            }
            let name = CommandLine.arguments[1]
            let fixture = WidgetFixture()
            var object = fixture.valid
            switch name {
            case "valid_round_trip":
                let snapshot = try fixture.required(object)
                try expect(snapshot.accountLabel == "账号 A", "只展示账号槽位")
                try expect(snapshot.passed == 13 && snapshot.warning == 1, "应保留通过和警告计数")
                let data = try JSONEncoder().encode(snapshot)
                let copy = StatusWidgetSnapshot.decode(data, now: fixture.now)
                try expect(copy?.currentAccount == "A" && copy?.status == "ready", "Codable 应与共享协议兼容")
            case "schema_and_fields":
                object["schemaVersion"] = 2
                try fixture.rejected(object, "未知 schema 不可沿用")
                object = fixture.valid
                object.removeValue(forKey: "pending")
                try fixture.rejected(object, "缺字段应拒绝")
                object = fixture.valid
                object["token"] = "synthetic-forbidden-field"
                try fixture.rejected(object, "额外字段不应进入脱敏摘要")
            case "malformed_and_size":
                for text in ["", "{}", "[]", "null", "not-json"] {
                    try expect(StatusWidgetSnapshot.decode(Data(text.utf8), now: fixture.now) == nil,
                               "无效 JSON 不可显示为通过")
                }
                try expect(StatusWidgetSnapshot.decode(Data(repeating: 32, count: 4097), now: fixture.now) == nil,
                           "超过大小限制的摘要应拒绝")
            case "account_privacy":
                for account in ["E", "203.0.113.42", "user@example.invalid", "A session=example", ""] {
                    object["currentAccount"] = account
                    try fixture.rejected(object, "只允许槽位与未知占位值")
                }
                for account in ["A", "B", "C", "D"] {
                    object["currentAccount"] = account
                    let snapshot = try fixture.required(object)
                    try expect(snapshot.accountLabel == "账号 \(account)", "合法槽位应保留")
                }
            case "unknown_account":
                for account in ["none", "unknown", "?", "未知", "未初始化"] {
                    object["currentAccount"] = account
                    let snapshot = try fixture.required(object)
                    try expect(snapshot.accountLabel == "尚无账号", "未知账号不可冒用 A 槽位")
                }
            case "phase_allowlist":
                for phase in ["checking", "ready", "failed", "fixing", "switching", "done", "unknown"] {
                    object["status"] = phase
                    let snapshot = try fixture.required(object)
                    try expect(snapshot.status == phase, "阶段不能被改成通过")
                }
                for phase in ["ok", "success", "READY", "", "arbitrary"] {
                    object["status"] = phase
                    try fixture.rejected(object, "未知阶段不应展示为通过")
                }
            case "count_total":
                for passed in [0, 12, 14] {
                    object["passed"] = passed
                    try fixture.rejected(object, "五类计数必须合计14")
                }
            case "count_range_and_types":
                for field in ["passed", "warning", "failed", "skipped", "pending"] {
                    for invalid: Any in [-1, 15, true, "1", 1.5] {
                        object = fixture.valid
                        object[field] = invalid
                        try fixture.rejected(object, "计数必须是0至14的整数，不能是布尔或字符串")
                    }
                }
                object = fixture.valid
                object["passed"] = 15
                object["warning"] = -1
                try fixture.rejected(object, "总数正确也不能放过越界分类计数")
            case "timestamp_boundaries":
                for timestamp in [0, fixture.now.timeIntervalSince1970, fixture.now.timeIntervalSince1970 + 60] {
                    object["checkedAt"] = timestamp
                    _ = try fixture.required(object)
                }
                for timestamp: Any in [-1, fixture.now.timeIntervalSince1970 + 61, true, "Infinity"] {
                    object["checkedAt"] = timestamp
                    try fixture.rejected(object, "无效与超出时钟容差的未来时间应拒绝")
                }
            case "stale_boundary":
                let snapshot = try fixture.required(object)
                try expect(!snapshot.isStale(at: fixture.now.addingTimeInterval(1799)), "30分钟前不应提前过期")
                try expect(snapshot.isStale(at: fixture.now.addingTimeInterval(1800)), "30分钟边界应过期")
                try expect(snapshot.isStale(at: fixture.now.addingTimeInterval(86400)), "旧结果不能复活")
                let entry = StatusWidgetEntry(date: fixture.now.addingTimeInterval(1800), snapshot: snapshot, configured: true)
                try expect(entry.headline == "结果已过期" && entry.resultTone == .muted,
                           "旧的通过结果必须显示为灰色过期状态")
            case "unchecked_and_pending":
                object["checkedAt"] = 0
                object["passed"] = 0
                object["warning"] = 0
                object["pending"] = 14
                object["status"] = "checking"
                let snapshot = try fixture.required(object)
                try expect(snapshot.checkedAt == 0 && snapshot.pending == 14 && snapshot.passed == 0,
                           "未检查状态不可转换为14项通过")
                try expect(!snapshot.isStale(at: fixture.now), "尚无结果与过期结果应保持不同")
                let entry = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                try expect(entry.headline == "尚未检查" && entry.resultTone == .muted,
                           "没有完成过检查时不能显示通过或假实时进度")
            case "skipped_is_not_passed":
                object["passed"] = 12
                object["warning"] = 0
                object["skipped"] = 2
                let snapshot = try fixture.required(object)
                try expect(snapshot.passed == 12 && snapshot.skipped == 2, "跳过不能计入通过")
                let copy = StatusWidgetSnapshot.decode(try JSONEncoder().encode(snapshot), now: fixture.now)
                try expect(copy?.passed == 12 && copy?.skipped == 2, "序列化不能把skip转成ok")
                let entry = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                try expect(entry.headline == "通过 · 含跳过" && entry.resultTone == .muted,
                           "含跳过结果必须明确标注并使用灰色")
            case "failure_is_not_passed":
                object["passed"] = 12
                object["warning"] = 1
                object["failed"] = 1
                object["status"] = "failed"
                let snapshot = try fixture.required(object)
                try expect(snapshot.status == "failed" && snapshot.failed == 1 && snapshot.passed == 12,
                           "失败状态和计数必须保留")
                let entry = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                try expect(entry.headline == "检查未通过" && entry.resultTone == .failure,
                           "失败不可展示成成功颜色")
            case "phase_is_historical":
                for (phase, label) in [("checking", "检查中"), ("fixing", "修复中"), ("switching", "切换中")] {
                    object["status"] = phase
                    let snapshot = try fixture.required(object)
                    let entry = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                    try expect(entry.headline == "上次状态：\(label)" && entry.resultTone == .muted,
                               "后台阶段必须标明为历史状态，而非伪实时")
                    let stale = StatusWidgetEntry(date: fixture.now.addingTimeInterval(1800), snapshot: snapshot, configured: true)
                    try expect(stale.headline == "结果已过期" && stale.resultTone == .muted,
                               "主应用退出后不能一直展示旧的进行中阶段")
                }
            case "failure_phase_stale", "failure_count_stale":
                if name == "failure_phase_stale" {
                    // 账号状态等审计失败可能没有对应的失败检查行。
                    object["status"] = "failed"
                    object["failed"] = 0
                } else {
                    // 阶段尚未同步时，失败计数也必须独立阻止通过。
                    object["status"] = "ready"
                    object["passed"] = 12
                    object["failed"] = 1
                }
                let snapshot = try fixture.required(object)
                for elapsed in [0.0, 1799.0, 1800.0, 86400.0] {
                    let entry = StatusWidgetEntry(date: fixture.now.addingTimeInterval(elapsed), snapshot: snapshot, configured: true)
                    let label = elapsed >= 1800 ? "未通过 · 结果已过期" : "检查未通过"
                    try expect(entry.headline == label && entry.resultTone == .failure,
                               "失败必须优先显示，不能被灰色过期提示覆盖")
                    try expect(entry.snapshot?.checkedAt == fixture.now.timeIntervalSince1970,
                               "显示失败不能刷新最近完整检查的时间")
                }
                let timeline = StatusWidgetProvider.timelineEntries(for: StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true))
                try expect(timeline.count == 2 && timeline[1].headline == "未通过 · 结果已过期" && timeline[1].resultTone == .failure,
                           "预先安排的过期时间线也必须保留失败提示")
            case "unchecked_failure":
                object["checkedAt"] = 0
                for phase in ["ready", "failed"] {
                    object["status"] = phase
                    for failures in [0, 1] {
                        object["failed"] = failures
                        object["passed"] = 13 - failures
                        let snapshot = try fixture.required(object)
                        let entry = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                        try expect(entry.headline == "尚未检查" && entry.resultTone == .muted,
                                   "没有完成过检查时，失败字段也不能伪装成已完成的结果")
                    }
                }
            case "unavailable_is_not_passed":
                let unconfigured = StatusWidgetEntry(date: fixture.now, snapshot: nil, configured: false)
                try expect(unconfigured.headline == "等待配置" && unconfigured.resultTone == .muted,
                           "缺少共享配置不能显示通过")
                let unavailable = StatusWidgetEntry(date: fixture.now, snapshot: nil, configured: true)
                try expect(unavailable.headline == "等待检查" && unavailable.resultTone == .muted,
                           "无数据不能显示通过")
                object["status"] = "unknown"
                let snapshot = try fixture.required(object)
                let unknown = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                try expect(unknown.headline == "等待检查" && unknown.resultTone == .muted,
                           "未知阶段不能显示旧的通过结果")
            case "timeline_schedules_expiration":
                object["passed"] = 14
                object["warning"] = 0
                let snapshot = try fixture.required(object)
                let current = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                let entries = StatusWidgetProvider.timelineEntries(for: current)
                try expect(entries.count == 2, "完整的新结果必须提前安排过期entry")
                try expect(entries[0].date == fixture.now && entries[0].headline == "最近检查通过",
                           "第一条应保留当前结果")
                try expect(entries[1].date == fixture.now.addingTimeInterval(1800), "过期entry必须精确落在检查后30分钟")
                try expect(entries[1].headline == "结果已过期" && entries[1].resultTone == .muted,
                           "系统不reload时未来entry也必须移除通过状态")
            case "timeline_expiration_boundary":
                let snapshot = try fixture.required(object)
                let justBefore = fixture.now.addingTimeInterval(1799)
                let current = StatusWidgetEntry(date: justBefore, snapshot: snapshot, configured: true)
                let entries = StatusWidgetProvider.timelineEntries(for: current)
                try expect(entries.count == 2 && entries[1].date.timeIntervalSince(justBefore) == 1,
                           "距过期一秒仍应安排过期entry，而不是等15分钟reload")
                for elapsed in [1800.0, 86400.0] {
                    let expired = StatusWidgetEntry(date: fixture.now.addingTimeInterval(elapsed), snapshot: snapshot, configured: true)
                    let result = StatusWidgetProvider.timelineEntries(for: expired)
                    try expect(result.count == 1 && result[0].headline == "结果已过期",
                               "边界与已过期结果不得添加重复或过去的entry")
                }
            case "timeline_waiting_has_no_past_date":
                for configured in [false, true] {
                    let empty = StatusWidgetEntry(date: fixture.now, snapshot: nil, configured: configured)
                    let entries = StatusWidgetProvider.timelineEntries(for: empty)
                    try expect(entries.count == 1 && entries[0].date == fixture.now,
                               "缺少配置或数据时不应生成1970年的过期entry")
                }
                object["checkedAt"] = 0
                object["status"] = "unknown"
                let snapshot = try fixture.required(object)
                let waiting = StatusWidgetEntry(date: fixture.now, snapshot: snapshot, configured: true)
                let entries = StatusWidgetProvider.timelineEntries(for: waiting)
                try expect(entries.count == 1 && entries[0].date == fixture.now && entries[0].headline == "尚未检查",
                           "未知且尚未检查的状态应保留当前时间，不能生成过去的entry")
                object["checkedAt"] = fixture.now.timeIntervalSince1970
                let unknown = try fixture.required(object)
                let unknownEntries = StatusWidgetProvider.timelineEntries(for: StatusWidgetEntry(date: fixture.now, snapshot: unknown, configured: true))
                try expect(unknownEntries.count == 2 && unknownEntries.allSatisfy { $0.date >= fixture.now },
                           "已有时间的未知阶段只允许当前与未来entry")
            default:
                throw WidgetTestFailure(description: "未知 Widget 测试场景：\(name)")
            }
            print("PASS \(name)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}

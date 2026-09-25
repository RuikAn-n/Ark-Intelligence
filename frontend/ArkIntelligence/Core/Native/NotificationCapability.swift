import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct ArkNotificationEvent: Codable, Sendable, Identifiable {
    var schema_version = "1.0"
    var kind = "notification.received"
    var adapter = "macos.notification-center.ax"
    var source_app: String
    var source_bundle_id: String?
    var source_id: String?
    var title: String
    var body: String
    var observed_at: String
    var occurred_at: String?
    var time_precision: String
    var time_label: String?
    var id: String? = nil
}

struct NotificationCapture: Sendable {
    let events: [ArkNotificationEvent]
    let warning: String
}

// New application adapters implement this boundary, without changing the event store.
@MainActor
protocol ApplicationEventAdapter {
    func capture() async throws -> NotificationCapture
}

struct NotificationAXNode: Sendable, Hashable {
    var role: String = ""
    var subrole: String = ""
    var identifier: String = ""
    var title: String = ""
    var value: String = ""
    var label: String = ""
    var actions: [String] = []
    var expanded: Bool?
    var positionY: Double?
    var scrollPosition: Double?
    var scrollAtBottom: Bool?
    var truncated = false
    var children: [NotificationAXNode] = []
}

enum NotificationCardParser {
    static func time(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "Just now" has minute-level resolution; use its midpoint, not capture time.
        if ["now", "just now", "现在", "刚刚"].contains(clean) { return now.addingTimeInterval(-30) }
        let patterns: [(String, Double)] = [
            (#"^(\d+)\s*(?:m|min|mins|minute|minutes) ago$"#, 60),
            (#"^(\d+)\s*(?:h|hr|hrs|hour|hours) ago$"#, 3600),
            (#"^(\d+)\s*分钟前$"#, 60), (#"^(\d+)\s*小时前$"#, 3600)
        ]
        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
                  let range = Range(match.range(at: 1), in: clean), let count = Double(clean[range]), count < 10000 else { continue }
            return now.addingTimeInterval(-count * multiplier)
        }
        // Calendar arithmetic preserves local dates across midnight and DST.
        let clockPattern = #"^(?:(今天|昨天|前天|today|yesterday)\s+)?(\d{1,2}):(\d{2})$"#
        if let regex = try? NSRegularExpression(pattern: clockPattern),
           let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) {
            func group(_ index: Int) -> String { Range(match.range(at: index), in: clean).map { String(clean[$0]) } ?? "" }
            let day = group(1), hour = Int(group(2))!, minute = Int(group(3))!
            guard hour < 24, minute < 60 else { return nil }
            let offset = ["昨天", "yesterday"].contains(day) ? -1 : day == "前天" ? -2 : 0
            guard let base = calendar.date(byAdding: .day, value: offset, to: now),
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base), date <= now else { return nil }
            return date
        }
        let formats = [
            (#"^\d{4}-\d{1,2}-\d{1,2} \d{1,2}:\d{2}$"#, "yyyy-MM-dd HH:mm"),
            (#"^\d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2}$"#, "yyyy/MM/dd HH:mm"),
            (#"^\d{4}年\d{1,2}月\d{1,2}日 \d{1,2}:\d{2}$"#, "yyyy年M月d日 HH:mm"),
            (#"^\d{1,2}月\d{1,2}日 \d{1,2}:\d{2}$"#, "M月d日 HH:mm")
        ]
        for (pattern, format) in formats where clean.range(of: pattern, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format; formatter.isLenient = false
            formatter.defaultDate = now
            if var date = formatter.date(from: clean) {
                if format == "M月d日 HH:mm", date > now { date = calendar.date(byAdding: .year, value: -1, to: date) ?? date }
                if date <= now { return date }
            }
        }
        return nil
    }

    static func trailingTime(_ text: String) -> (content: String, label: String)? {
        let pattern = #"\s+((?:(?:今天|昨天|前天|today|yesterday)\s+)?\d{1,2}:\d{2}|\d{4}[-/]\d{1,2}[-/]\d{1,2}\s+\d{1,2}:\d{2}|(?:\d{4}年)?\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}|\d+\s*(?:分钟|小时|天)前|\d+\s+(?:minutes?|hours?|days?) ago|刚刚|just now)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text) else { return nil }
        return (String(text[..<whole.lowerBound]), String(text[label]))
    }

    static func parse(_ root: NotificationAXNode, now: Date) -> [ArkNotificationEvent] {
        func cards(_ node: NotificationAXNode, inList: Bool = false) -> [NotificationAXNode] {
            if NotificationNavigation.isCollapsedStack(node) { return [] }
            // Prefer leaf cards to avoid conflating an application stack with a message.
            let context = inList || node.identifier == "AXNotificationListItems" || node.subrole.hasPrefix("AXNotificationCenter")
            let nested = node.children.flatMap { cards($0, inList: context) }
            if !nested.isEmpty { return nested }
            let directFields = Set(node.children.map { $0.identifier.lowercased() })
            if context && node.role == "AXGroup" && directFields.contains("title") && directFields.contains("body") { return [node] }
            let id = node.identifier.lowercased()
            let subroles = ["AXNotificationCenterBanner", "AXNotificationCenterAlert", "AXNotificationCenterNotification", "AXNotificationCenterAlertStack"]
            if subroles.contains(node.subrole) || (id.contains("notification") && (id.contains("card") || id.contains("entry"))) {
                return [node]
            }
            return []
        }
        func fields(_ node: NotificationAXNode) -> [NotificationAXNode] { [node] + node.children.flatMap(fields) }
        return cards(root).compactMap { card in
            let nodes = fields(card)
            func field(_ keys: [String]) -> String? {
                for key in keys {
                    let matches = nodes.filter { node in
                        let id = node.identifier.lowercased()
                        return id == key || (id.hasSuffix(key) && !(key == "title" && id.hasSuffix("subtitle")))
                    }
                    if let value = matches.compactMap({ node in [node.value, node.title, node.label].first { !$0.isEmpty } }).first { return value }
                }
                return nil
            }
            var texts: [String] = []
            for node in nodes where node.role == "AXStaticText" {
                if let text = [node.value, node.title, node.label].first(where: { !$0.isEmpty }), !texts.contains(text) { texts.append(text) }
            }
            let header = field(["header"])
            let headerParts = (header ?? "").components(separatedBy: CharacterSet(charactersIn: "，,\n")).map { $0.trimmingCharacters(in: .whitespaces) }
            let headerTime = headerParts.last.flatMap { time($0, now: now) == nil ? nil : $0 }
            let descriptionApp = card.label.components(separatedBy: "，").count > 1 ? card.label.components(separatedBy: "，").first : nil
            let app = field(["appname", "app-name", "applicationname"]) ?? descriptionApp ?? (headerTime != nil && headerParts.count == 2 ? headerParts[0] : header) ?? "未知应用"
            let explicitTime = field(["timestamp", "date", "time"]) ?? headerTime ?? nodes.first { $0.role == "AXStaticText" && !["title", "body", "message", "subtitle"].contains($0.identifier.lowercased()) && time($0.value, now: now) != nil }?.value
            // Mirrored notifications combine title, body and system timestamp in one field.
            // Never infer a receive time from a separate message/body (it may be a deadline).
            let candidate = field(["body", "message"]) == nil ? (field(["title"]) ?? header).flatMap(trailingTime) : nil
            func normalized(_ text: String) -> String { text.components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters)).joined() }
            // AXDescription mirrors message content but omits the system timestamp.
            // Require that independent evidence before stripping a title suffix.
            let combined = candidate.flatMap { candidate -> (content: String, label: String)? in
                let description = normalized(card.label)
                guard !description.isEmpty, !candidate.content.isEmpty,
                      description.contains(normalized(candidate.content)),
                      !description.hasSuffix(normalized(candidate.label)) else { return nil }
                return candidate
            }
            let timeLabel = explicitTime ?? combined?.label
            let content = texts.filter { $0 != app && $0 != timeLabel && $0 != header }
            let title = combined?.content ?? field(["title"]) ?? content.first ?? ""
            let explicitBody = [field(["subtitle"]), field(["body", "message"])].compactMap { $0 }.joined(separator: "\n")
            let body = explicitBody.isEmpty ? content.filter { $0 != title && $0 != field(["title"]) }.joined(separator: "\n") : explicitBody
            guard !title.isEmpty || !body.isEmpty else { return nil }
            let occurred = timeLabel.flatMap { time($0, now: now) }
            // Generic role IDs repeat across cards, so never use them as source identity.
            return ArkNotificationEvent(source_app: String(app.prefix(200)), title: String(title.prefix(1000)), body: String(body.prefix(4000)), observed_at: now.ISO8601Format(), occurred_at: occurred?.ISO8601Format(), time_precision: occurred == nil ? "unknown" : "approximate", time_label: timeLabel.map { String($0.prefix(200)) })
        }
    }
}

@MainActor
final class NotificationCenterAXAdapter: ApplicationEventAdapter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func capture() async throws -> NotificationCapture {
        let worker = Task.detached(priority: .userInitiated) {
            try await NotificationAXReader().capture()
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private final class NotificationAXReader: NotificationSweepDriver {
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func snapshot(_ element: AXUIElement, remaining: inout Int, depth: Int = 0, deadline: Date) -> NotificationAXNode {
        guard remaining > 0, depth < 24, Date() < deadline else { return NotificationAXNode(truncated: true) }
        remaining -= 1
        func text(_ key: String) -> String { String(((attribute(element, key) as? String) ?? "").prefix(4000)) }
        let node = NotificationAXNode(role: text(kAXRoleAttribute), subrole: text(kAXSubroleAttribute), identifier: text(kAXIdentifierAttribute), title: text(kAXTitleAttribute), value: text(kAXValueAttribute), label: text(kAXDescriptionAttribute))
        var result = node
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success { result.actions = (names as? [String]) ?? [] }
        result.expanded = attribute(element, kAXExpandedAttribute) as? Bool
        if let raw = attribute(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(raw as! AXValue, .cgPoint, &point) { result.positionY = point.y }
        }
        if node.role == "AXScrollArea", let raw = attribute(element, kAXVerticalScrollBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let bar = raw as! AXUIElement
            if let value = attribute(bar, kAXValueAttribute) as? NSNumber {
                result.scrollPosition = value.doubleValue
                if let maximum = attribute(bar, kAXMaxValueAttribute) as? NSNumber {
                    result.scrollAtBottom = value.doubleValue >= maximum.doubleValue
                }
            }
        }
        for child in children(element) where remaining > 0 && Date() < deadline {
            result.children.append(snapshot(child, remaining: &remaining, depth: depth + 1, deadline: deadline))
        }
        result.truncated = remaining <= 0 || Date() >= deadline || result.children.contains { $0.truncated }
        return result
    }

    private func openCenter() -> Bool {
        // Press only the system clock menu item. Never press notification cards/actions.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var queue = [root], visited = 0
        for name in [kAXMenuBarAttribute, "AXExtrasMenuBar"] {
            if let value = attribute(root, name), CFGetTypeID(value) == AXUIElementGetTypeID() { queue.append(value as! AXUIElement) }
        }
        let deadline = Date().addingTimeInterval(3)
        while !queue.isEmpty && visited < 150 && Date() < deadline {
            let node = queue.removeFirst(); visited += 1
            let id = (attribute(node, kAXIdentifierAttribute) as? String ?? "").lowercased()
            if id.contains("clock") { return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success }
            queue.append(contentsOf: children(node))
        }
        return false
    }

    private func windows() -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        return (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private var targets: [String: AXUIElement] = [:]
    private var wroteDiagnostic = false

    func capture() async throws -> NotificationCapture {
        guard AXIsProcessTrusted() else { throw NativeActionError(code: "PERMISSION_DENIED", message: "请在系统设置中重新添加当前 Ark 应用并允许辅助功能，再重启 Ark。") }
        let visible = windows().contains { ["通知中心", "Notification Center"].contains(attribute($0, kAXTitleAttribute) as? String ?? "") }
        if !visible { _ = openCenter(); try await Task.sleep(for: .milliseconds(600)) }
        let captured = try await NotificationSweep.collect(driver: self)
        guard !captured.events.isEmpty else {
            throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "未采集到通知。通知中心可能为空，或当前系统未暴露可识别的展开/读取操作。" + captured.warning)
        }
        return captured
    }

    func readPage(deadline: Date) throws -> NotificationAXNode {
        guard AXIsProcessTrusted() else { throw NativeActionError(code: "PERMISSION_DENIED", message: "辅助功能权限已撤销，采集已停止。") }
        targets.removeAll()
        var budget = 2500
        var root = NotificationAXNode()
        for (index, window) in windows().enumerated() {
            AXUIElementSetMessagingTimeout(window, 0.1)
            root.children.append(snapshot(window, remaining: &budget, deadline: min(deadline, Date().addingTimeInterval(5))))
            targets[String(index)] = window
        }
        if !wroteDiagnostic { writeStructureDiagnostic(root); wroteDiagnostic = true }
        return root
    }

    private func writeStructureDiagnostic(_ root: NotificationAXNode) {
        // Structural diagnostics only: never store notification titles, bodies or app names.
        var rows: [[String: Any]] = []
        func visit(_ node: NotificationAXNode, depth: Int) {
            guard rows.count < 150 else { return }
            if node.role != "AXStaticText" {
                rows.append(["depth": depth, "role": node.role, "subrole": node.subrole,
                             "isList": node.identifier == "AXNotificationListItems",
                             "labelHasStackMarker": node.label.contains("已叠放"),
                             "labelEndsInStackMarker": node.label.hasSuffix("，已叠放，来自iPhone") || node.label.hasSuffix("，已叠放"),
                             "expanded": node.expanded.map { String($0) } ?? "absent",
                             "actions": node.actions.map { String($0.prefix(250)) }])
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = base.appendingPathComponent("ArkIntelligence/runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("notification-ax-structure.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private(set) var lastFailure: String?

    func perform(_ command: NotificationNavigation.Command) -> Bool {
        lastFailure = nil
        func fail(_ message: String) -> Bool { lastFailure = message; return false }
        func checked(_ error: AXError, stage: String) -> Bool {
            error == .success ? true : fail("\(stage)：AX 错误 \(error.rawValue)")
        }
        guard AXIsProcessTrusted() else { return fail("辅助功能权限失效") }
        guard let first = command.path.first, var target = targets[String(first)] else { return fail("目标窗口已变化") }
        for index in command.path.dropFirst() {
            let list = children(target)
            guard list.indices.contains(index) else { return fail("目标路径已变化") }
            target = list[index]
        }
        var budget = 2500
        let fresh = snapshot(target, remaining: &budget, deadline: Date().addingTimeInterval(2))
        guard NotificationNavigation.matchesTarget(fresh, command: command) else { return fail("目标重新校验失败") }
        // Reading missing attributes should fail quickly; UI actions may wait for layout.
        // Do not inherit the 100 ms snapshot timeout for a page-scroll operation.
        AXUIElementSetMessagingTimeout(target, 2)
        defer { AXUIElementSetMessagingTimeout(target, 0.1) }
        if command.action == "scroll-wheel-down" || command.action == "scroll-wheel-up" {
            guard fresh.role == "AXScrollArea", NotificationNavigation.containsNotifications(fresh),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return fail("通知滚动目标不可用") }
            var pid: pid_t = 0
            guard AXUIElementGetPid(target, &pid) == .success, pid == app.processIdentifier else { return fail("滚动目标不是通知中心") }
            guard let rawPosition = attribute(target, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  let rawSize = attribute(target, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return fail("无法读取通知列表范围") }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
                  AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
                  let gesture = NotificationNavigation.wheelGesture(in: CGRect(origin: point, size: size), up: command.action == "scroll-wheel-up") else { return fail("通知列表范围无效") }
            let viewport = CGRect(origin: point, size: size)
            // A scroll area can span the screen; its center may be blank space.
            // Find a visible notification card and hit-test its point before global input.
            func frame(_ node: AXUIElement) -> CGRect? {
                guard let p = attribute(node, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                      let s = attribute(node, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
                var origin = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &dimensions) else { return nil }
                return CGRect(origin: origin, size: dimensions)
            }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var queue = children(target), inspected = 0
            var landing: CGPoint?
            let landingDeadline = Date().addingTimeInterval(2)
            while !queue.isEmpty && inspected < 500 && Date() < landingDeadline {
                let node = queue.removeFirst(); inspected += 1
                let subrole = attribute(node, kAXSubroleAttribute) as? String ?? ""
                if subrole.hasPrefix("AXNotificationCenter"), let bounds = frame(node),
                   let candidate = NotificationNavigation.wheelLanding(card: bounds, viewport: viewport) {
                    var hit: AXUIElement?
                    var hitPID: pid_t = 0
                    if AXUIElementCopyElementAtPosition(system, Float(candidate.x), Float(candidate.y), &hit) == .success,
                       let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid {
                        landing = candidate; break
                    }
                }
                queue.append(contentsOf: children(node))
            }
            guard let landing else { return fail("未找到属于通知中心的可见滚动落点") }
            guard let current = CGEvent(source: nil),
                  let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: landing, mouseButton: .left),
                  let restore = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: current.location, mouseButton: .left),
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: gesture.delta, wheel2: 0, wheel3: 0) else { return fail("无法创建滚轮事件") }
            event.location = landing
            move.post(tap: .cghidEventTap)
            event.post(tap: .cghidEventTap)
            restore.post(tap: .cghidEventTap)
            // Posting has no success result. The sweep must verify actual card movement.
            return true
        }
        if ["set-top", "scroll-bar-down"].contains(command.action) {
            guard fresh.role == "AXScrollArea", NotificationNavigation.containsNotifications(fresh),
                  let raw = attribute(target, kAXVerticalScrollBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return fail("通知区域未提供垂直滚动条") }
            let bar = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, 2)
            defer { AXUIElementSetMessagingTimeout(bar, 0.1) }
            if command.action == "set-top" {
                guard let value = attribute(bar, kAXMinValueAttribute) as? NSNumber else { return fail("无法读取滚动条起点") }
                return checked(AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, value), stage: "回到顶部")
            }
            if let value = attribute(bar, kAXValueAttribute) as? NSNumber,
               let maximum = attribute(bar, kAXMaxValueAttribute) as? NSNumber, value.doubleValue >= maximum.doubleValue { return fail("垂直滚动条已到末端") }
            var actions: CFArray?
            guard AXUIElementCopyActionNames(bar, &actions) == .success,
                  (actions as? [String] ?? []).contains(kAXIncrementAction) else { return fail("垂直滚动条未提供增量操作") }
            return checked(AXUIElementPerformAction(bar, kAXIncrementAction as CFString), stage: "滚动条增量操作")
        }
        guard fresh.actions.contains(command.action) else { return fail("目标已不提供 \(command.action)") }
        return checked(AXUIElementPerformAction(target, command.action as CFString), stage: command.action)
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

}

@MainActor
final class NotificationCapability {
    private let adapter: any ApplicationEventAdapter = NotificationCenterAXAdapter()

    func prepare() -> (preview: [String: JSONValue], read: [String: JSONValue]?) {
        (["summary": .string("自动打开通知中心、展开分组并滚动采集，保存到 Ark 本机供按时间总结。")], nil)
    }

    func execute() async throws -> [String: JSONValue] {
        let captured = try await adapter.capture()
        let events = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(captured.events))
        return ["events": events, "coverage": .string(captured.warning), "verified": .bool(true)]
    }
}

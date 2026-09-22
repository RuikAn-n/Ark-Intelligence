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

struct NotificationAXNode: Sendable {
    var role: String = ""
    var subrole: String = ""
    var identifier: String = ""
    var title: String = ""
    var value: String = ""
    var label: String = ""
    var children: [NotificationAXNode] = []
}

enum NotificationCardParser {
    static func time(_ text: String, now: Date) -> Date? {
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
        return nil
    }

    static func parse(_ root: NotificationAXNode, now: Date) -> [ArkNotificationEvent] {
        func cards(_ node: NotificationAXNode, inList: Bool = false) -> [NotificationAXNode] {
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
            let app = field(["appname", "app-name", "applicationname"]) ?? (headerTime != nil && headerParts.count == 2 ? headerParts[0] : header) ?? "未知应用"
            let timeLabel = field(["timestamp", "date", "time"]) ?? headerTime ?? texts.first { time($0, now: now) != nil }
            let content = texts.filter { $0 != app && $0 != timeLabel && $0 != header }
            let title = field(["title"]) ?? content.first ?? ""
            let explicitBody = [field(["subtitle"]), field(["body", "message"])].compactMap { $0 }.joined(separator: "\n")
            let body = explicitBody.isEmpty ? content.filter { $0 != title }.joined(separator: "\n") : explicitBody
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

private final class NotificationAXReader {
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func snapshot(_ element: AXUIElement, remaining: inout Int, depth: Int = 0, deadline: Date) -> NotificationAXNode {
        guard remaining > 0, depth < 24, Date() < deadline else { return NotificationAXNode() }
        remaining -= 1
        func text(_ key: String) -> String { String(((attribute(element, key) as? String) ?? "").prefix(4000)) }
        let node = NotificationAXNode(role: text(kAXRoleAttribute), subrole: text(kAXSubroleAttribute), identifier: text(kAXIdentifierAttribute), title: text(kAXTitleAttribute), value: text(kAXValueAttribute), label: text(kAXDescriptionAttribute))
        var result = node
        for child in children(element) where remaining > 0 && Date() < deadline {
            result.children.append(snapshot(child, remaining: &remaining, depth: depth + 1, deadline: deadline))
        }
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

    func capture() async throws -> NotificationCapture {
        guard AXIsProcessTrusted() else { throw NativeActionError(code: "PERMISSION_DENIED", message: "请在系统设置的辅助功能中允许 Ark Intelligence，再重试。") }
        func centerWindows() -> [AXUIElement] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.2)
            return (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        }
        var windows = centerWindows()
        let panelVisible = windows.contains { window in
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            return ["通知中心", "Notification Center"].contains(title)
        }
        if !panelVisible {
            _ = openCenter()
            try await Task.sleep(for: .milliseconds(600))
            windows = centerWindows()
        }
        guard !windows.isEmpty else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "未读到通知中心窗口。请点击菜单栏日期打开通知中心，展开通知分组后重试。") }
        let now = Date(), deadline = Date().addingTimeInterval(8)
        var remaining = 2500
        var events: [ArkNotificationEvent] = []
        for window in windows {
            try Task.checkCancellation()
            AXUIElementSetMessagingTimeout(window, 0.1)
            let root = snapshot(window, remaining: &remaining, deadline: deadline)
            events += NotificationCardParser.parse(root, now: now)
        }
        guard !events.isEmpty else { throw NativeActionError(code: "CAPABILITY_UNAVAILABLE", message: "未识别到可读取的通知卡片。通知可能为空、已折叠，或当前 macOS 的辅助功能结构尚不受支持。请展开通知后重试；可单独总结已采集记录。") }
        return NotificationCapture(events: Array(events.prefix(500)), warning: "仅采集通知中心当前暴露的卡片；请展开所需分组。已清除、隐藏预览、未加载内容无法补回；单条标题最多 1000 字、正文最多 4000 字。" + (remaining == 0 || Date() >= deadline || events.count > 500 ? "本次扫描达到上限，请分批采集。" : ""))
    }
}

@MainActor
final class NotificationCapability {
    private let adapter: any ApplicationEventAdapter = NotificationCenterAXAdapter()

    func prepare() -> (preview: [String: JSONValue], read: [String: JSONValue]?) {
        (["summary": .string("读取通知中心当前可见通知并保存到 Ark 本机，供按时间总结；可能打开通知中心。")], nil)
    }

    func execute() async throws -> [String: JSONValue] {
        let captured = try await adapter.capture()
        let events = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(captured.events))
        return ["events": events, "coverage": .string(captured.warning), "verified": .bool(true)]
    }
}

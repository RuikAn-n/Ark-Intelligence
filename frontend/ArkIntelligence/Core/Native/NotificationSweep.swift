import Foundation

enum NotificationNavigation {
    static func wheelLanding(card: CGRect, viewport: CGRect) -> CGPoint? {
        guard [card.minX, card.minY, card.width, card.height, viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy({ $0.isFinite }) else { return nil }
        let visible = card.intersection(viewport)
        guard !visible.isNull, visible.width >= 20, visible.height >= 20 else { return nil }
        return CGPoint(x: visible.midX, y: visible.midY)
    }
    static func wheelGesture(in frame: CGRect, up: Bool) -> (point: CGPoint, delta: Int32)? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width >= 20, frame.height >= 20 else { return nil }
        let distance = Int32(min(360, frame.height * 0.6))
        return (CGPoint(x: frame.midX, y: frame.midY), up ? distance : -distance)
    }
    struct Command: Hashable {
        let path: [Int]
        let action: String
        let expected: NotificationAXNode
    }

    static func normalized(_ action: String) -> String {
        // Notification Center's named actions can include a trailing selector suffix.
        action.components(separatedBy: .newlines).first!.replacingOccurrences(of: #",\s*Target:.*$"#, with: "", options: .regularExpression).replacingOccurrences(of: "Name:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isCollapsedStack(_ node: NotificationAXNode) -> Bool {
        guard node.expanded != true else { return false }
        let names = Set(node.actions.map(normalized))
        let markedStack = node.label.hasSuffix("，已叠放，来自iPhone") || node.label.hasSuffix("，已叠放")
        let knownStack = ["AXNotificationCenterAlertStack", "AXNotificationCenterBannerStack"].contains(node.subrole)
        return (knownStack || (node.role == "AXGroup" && markedStack)) && names.contains("axpress") &&
            names.isDisjoint(with: ["close", "关闭"]) &&
            !names.isDisjoint(with: ["show details", "显示详细信息", "显示详情"]) &&
            !names.isDisjoint(with: ["clear all", "全部清除", "清除全部", "全部清除通知"])
    }

    static func containsNotifications(_ node: NotificationAXNode) -> Bool {
        node.identifier == "AXNotificationListItems" || node.subrole.hasPrefix("AXNotificationCenter") || node.children.contains(where: containsNotifications)
    }

    static func matchesTarget(_ fresh: NotificationAXNode, command: Command) -> Bool {
        if command.expected.role == "AXScrollArea" {
            // Notification text and relative timestamps can change between snapshots.
            return fresh.role == "AXScrollArea" && fresh.identifier == command.expected.identifier &&
                fresh.subrole == command.expected.subrole && containsNotifications(fresh)
        }
        return fresh == command.expected
    }

    static func viewportMoved(from before: NotificationAXNode, to after: NotificationAXNode) -> Bool {
        if let a = before.scrollPosition, let b = after.scrollPosition { return abs(a - b) > 0.000001 }
        func positions(_ node: NotificationAXNode) -> [String: Double] {
            var result: [String: Double] = [:]
            func walk(_ item: NotificationAXNode) {
                if item.subrole.hasPrefix("AXNotificationCenter"), !item.identifier.isEmpty, let y = item.positionY {
                    result[item.identifier] = y
                }
                item.children.forEach(walk)
            }
            walk(node)
            return result
        }
        let old = positions(before), new = positions(after)
        return old.contains { id, y in new[id].map { abs($0 - y) > 1 } ?? false }
    }

    static func expansion(_ root: NotificationAXNode, excluding: Set<Command> = []) -> Command? {
        func walk(_ node: NotificationAXNode, path: [Int], inList: Bool) -> Command? {
            let scoped = inList || node.identifier == "AXNotificationListItems" || node.subrole.hasPrefix("AXNotificationCenter")
            var action: String?
            if scoped && isCollapsedStack(node) { action = "AXPress" }
            else if scoped && node.expanded == false {
                action = node.actions.first { $0 == "AXExpand" }
                if action == nil && node.role == "AXDisclosureTriangle" { action = node.actions.first { $0 == "AXPress" } }
            }
            if let action {
                let command = Command(path: path, action: action, expected: node)
                if !excluding.contains(command) { return command }
            }
            for (index, child) in node.children.enumerated() {
                if let command = walk(child, path: path + [index], inList: scoped) { return command }
            }
            return nil
        }
        return walk(root, path: [], inList: false)
    }

    static func scroll(_ root: NotificationAXNode, top: Bool = false) -> Command? {
        func walk(_ node: NotificationAXNode, path: [Int]) -> Command? {
            if node.role == "AXScrollArea" && containsNotifications(node) {
                if top { return Command(path: path, action: "set-top", expected: node) }
                if let action = node.actions.first(where: { $0 == "AXScrollDownByPage" }) {
                    return Command(path: path, action: action, expected: node)
                }
                return Command(path: path, action: "scroll-bar-down", expected: node)
            }
            for (i, child) in node.children.enumerated() {
                if let command = walk(child, path: path + [i]) { return command }
            }
            return nil
        }
        return walk(root, path: [])
    }
}

protocol NotificationSweepDriver {
    var lastFailure: String? { get }
    func readPage(deadline: Date) throws -> NotificationAXNode
    func perform(_ command: NotificationNavigation.Command) -> Bool
    func settle() async throws
}

extension NotificationSweepDriver {
    var lastFailure: String? { nil }
}

enum NotificationSweep {
    static func collect(driver: any NotificationSweepDriver, maxSteps: Int = 100, timeout: TimeInterval = 40, now: Date = Date()) async throws -> NotificationCapture {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(timeout)
        var events: [ArkNotificationEvent] = []
        var seen = Set<String>()
        var attempted = Set<NotificationNavigation.Command>()
        var expanded = 0, scrolled = 0
        var warnings = Set<String>()
        var page = try driver.readPage(deadline: deadline)
        if let top = NotificationNavigation.scroll(page, top: true) {
            if driver.perform(top) {
                try await driver.settle(); page = try driver.readPage(deadline: deadline)
            } else {
                // No scrollbar is required: attempt bounded upward wheel gestures first.
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    guard Date() < deadline, let area = NotificationNavigation.scroll(page) else { break }
                    let up = NotificationNavigation.Command(path: area.path, action: "scroll-wheel-up", expected: area.expected)
                    guard driver.perform(up) else { break }
                    try await driver.settle()
                    let after = try driver.readPage(deadline: deadline)
                    let moved = NotificationNavigation.scroll(after).map { NotificationNavigation.viewportMoved(from: area.expected, to: $0.expected) } ?? false
                    page = after
                    if !moved { break }
                }
                warnings.insert("已尝试向上定位；系统未提供可核实的顶部位置，结果可能缺失。")
            }
        }
        for step in 0..<maxSteps {
            try Task.checkCancellation()
            guard Date() < deadline else { warnings.insert("达到采集时间上限，结果可能不完整。"); break }
            func truncated(_ node: NotificationAXNode) -> Bool { node.truncated || node.children.contains(where: truncated) }
            if truncated(page) { warnings.insert("部分界面读取达到节点或时间上限，内容可能缺失。") }
            if step == maxSteps - 1 { warnings.insert("达到操作次数上限，结果可能不完整。") }
            // Use one reference time throughout the sweep so the same relative label dedups.
            for event in NotificationCardParser.parse(page, now: now) {
                let key = [event.source_app, event.title, event.body, event.time_label ?? ""].joined(separator: "\u{0}")
                if seen.insert(key).inserted { events.append(event) }
            }
            if events.count >= 500 { warnings.insert("达到 500 条采集上限。"); break }
            if let command = NotificationNavigation.expansion(page, excluding: attempted) {
                attempted.insert(command)
                if driver.perform(command) {
                    expanded += 1
                    try await driver.settle()
                } else { warnings.insert("部分分组未能自动展开。"); }
                page = try driver.readPage(deadline: deadline)
                continue
            }
            if NotificationNavigation.expansion(page) != nil { warnings.insert("部分分组展开后没有变化，已跳过以避免重复操作。") }
            guard let initial = NotificationNavigation.scroll(page) else {
                warnings.insert("未找到通知滚动区域，无法确认已到列表底部。")
                break
            }
            if initial.expected.scrollAtBottom == true {
                warnings.insert("垂直滚动条位置确认已到当前列表底部。")
                break
            }
            let actions = initial.action == "scroll-bar-down" ? ["scroll-wheel-down", initial.action] : ["scroll-wheel-down", initial.action, "scroll-bar-down"]
            var moved = false
            var failures: [String] = []
            for action in actions {
                try Task.checkCancellation()
                guard Date() < deadline else { break }
                // Resolve each fallback against a new snapshot, never reuse a stale path.
                page = try driver.readPage(deadline: deadline)
                guard let current = NotificationNavigation.scroll(page) else { break }
                let command = NotificationNavigation.Command(path: current.path, action: action, expected: current.expected)
                guard driver.perform(command) else {
                    failures.append("\(action)：\(driver.lastFailure ?? "执行失败")")
                    continue
                }
                try await driver.settle()
                let after = try driver.readPage(deadline: deadline)
                let nextArea = NotificationNavigation.scroll(after)?.expected
                if let nextArea, NotificationNavigation.viewportMoved(from: current.expected, to: nextArea) {
                    moved = true
                    scrolled += 1
                    if !failures.isEmpty { warnings.insert("已通过后备方式滚动；此前操作：" + failures.joined(separator: "；") + "。") }
                    page = after
                    break
                }
                page = after
                failures.append("\(action)：操作返回成功，但未观察到滚动位置变化")
            }
            guard moved else {
                warnings.insert("滚动未完成，无法确认到达底部，结果可能缺失。" + failures.joined(separator: "；"))
                break
            }
            if step == maxSteps - 1 { warnings.insert("达到操作次数上限，结果可能不完整。") }
        }
        let coverage = "自动展开 \(expanded) 次、滚动 \(scrolled) 次。已清除、隐藏预览和系统未暴露的通知无法补回。相同内容与时间标签可能合并；标题最多 1000 字、正文最多 4000 字。"
        return NotificationCapture(events: Array(events.prefix(500)), warning: coverage + warnings.sorted().joined())
    }
}

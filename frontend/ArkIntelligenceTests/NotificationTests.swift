import XCTest
@testable import ArkIntelligence

final class NotificationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func card(app: String = "微信", time: String = "5分钟前") -> NotificationAXNode {
        NotificationAXNode(role: "AXGroup", subrole: "AXNotificationCenterAlert", children: [
            NotificationAXNode(role: "AXStaticText", identifier: "header", value: app),
            NotificationAXNode(role: "AXStaticText", identifier: "title", value: "测试联系人"),
            NotificationAXNode(role: "AXStaticText", identifier: "body", value: "下午讨论项目"),
            NotificationAXNode(role: "AXStaticText", identifier: "timestamp", value: time)
        ])
    }

    func testMultipleAppsAndStackDoesNotDuplicateCards() {
        let root = NotificationAXNode(subrole: "AXNotificationCenterAlertStack", children: [card(), card(app: "Slack")])
        let events = NotificationCardParser.parse(root, now: now)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.source_app), ["微信", "Slack"])
        XCTAssertEqual(events[0].body, "下午讨论项目")
        XCTAssertEqual(events[0].occurred_at, now.addingTimeInterval(-300).ISO8601Format())
        XCTAssertEqual(events[0].time_precision, "approximate")
    }

    func testUnknownTimeIsNotObservationTime() {
        let event = NotificationCardParser.parse(card(time: "昨天"), now: now).first!
        XCTAssertNil(event.occurred_at)
        XCTAssertEqual(event.time_precision, "unknown")
        XCTAssertEqual(event.observed_at, now.ISO8601Format())
    }

    func testHeaderTimeAndSubtitleStaySeparate() {
        var node = card()
        node.children.removeLast()
        node.children[0].value = "微信, 2分钟前"
        node.children.insert(NotificationAXNode(role: "AXStaticText", identifier: "subtitle", value: "项目群"), at: 1)
        let event = NotificationCardParser.parse(node, now: now).first!
        XCTAssertEqual(event.source_app, "微信")
        XCTAssertEqual(event.title, "测试联系人")
        XCTAssertEqual(event.body, "项目群\n下午讨论项目")
        XCTAssertEqual(event.occurred_at, now.addingTimeInterval(-120).ISO8601Format())
    }

    func testWidgetAndNotificationListAreNotCards() {
        let widget = NotificationAXNode(identifier: "widget-weather", children: [NotificationAXNode(role: "AXStaticText", value: "Sunny")])
        XCTAssertTrue(NotificationCardParser.parse(widget, now: now).isEmpty)
        let list = NotificationAXNode(identifier: "AXNotificationListItems", children: [card(), card()])
        XCTAssertEqual(NotificationCardParser.parse(list, now: now).count, 2)
    }

    func testListCardsWithoutSubrolesAreKeptSeparate() {
        var first = card(), second = card(app: "Slack")
        first.subrole = ""; second.subrole = ""
        let list = NotificationAXNode(identifier: "AXNotificationListItems", children: [first, second])
        XCTAssertEqual(NotificationCardParser.parse(list, now: now).map(\.source_app), ["微信", "Slack"])
    }

    func testNotificationTextDoesNotBecomeTimeBySubstring() {
        XCTAssertNil(NotificationCardParser.time("会议将在5分钟前开始", now: now))
        XCTAssertNil(NotificationCardParser.time("明天 10:00", now: now))
        XCTAssertEqual(NotificationCardParser.time("2 hours ago", now: now), now.addingTimeInterval(-7200))
    }

    func testCalendarTimesAndInvalidLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let reference = ISO8601DateFormatter().date(from: "2026-09-24T02:19:00Z")!
        let expected = ISO8601DateFormatter().date(from: "2026-09-23T12:40:00Z")!
        for label in ["昨天 20:40", "yesterday 20:40", "2026-09-23 20:40", "2026/09/23 20:40", "2026年9月23日 20:40", "9月23日 20:40"] {
            XCTAssertEqual(NotificationCardParser.time(label, now: reference, calendar: calendar), expected, label)
        }
        XCTAssertEqual(NotificationCardParser.time("09:30", now: reference, calendar: calendar), ISO8601DateFormatter().date(from: "2026-09-24T01:30:00Z"))
        for label in ["昨天", "2天前", "12:00", "昨天 25:00", "2026-02-30 09:00", "2026-09-23 20:40 开会"] {
            XCTAssertNil(NotificationCardParser.time(label, now: reference, calendar: calendar), label)
        }
    }

    func testMirroredTimestampRequiresIndependentDescription() {
        let node = NotificationAXNode(role: "AXGroup", subrole: "AXNotificationCenterAlert", label: "微信，测试联系人，下午讨论项目", children: [
            NotificationAXNode(role: "AXStaticText", identifier: "title", value: "测试联系人 下午讨论项目 5分钟前")
        ])
        let event = NotificationCardParser.parse(node, now: now).first!
        XCTAssertEqual(event.source_app, "微信")
        XCTAssertEqual(event.title, "测试联系人 下午讨论项目")
        XCTAssertEqual(event.time_label, "5分钟前")
        XCTAssertEqual(event.occurred_at, now.addingTimeInterval(-300).ISO8601Format())
        var deadline = node
        deadline.label = "微信，测试联系人，会议时间 09:00"
        deadline.children[0].value = "测试联系人 会议时间 09:00"
        let unchanged = NotificationCardParser.parse(deadline, now: now).first!
        XCTAssertNil(unchanged.occurred_at)
        XCTAssertEqual(unchanged.title, deadline.children[0].value)
        var body = card()
        body.children.removeLast()
        body.children[2].value = "09:00"
        XCTAssertNil(NotificationCardParser.parse(body, now: now).first!.occurred_at)
    }

    func testIngestEncodingOmitsServerAssignedID() throws {
        let event = NotificationCardParser.parse(card(), now: now).first!
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["id"])
        XCTAssertEqual(object["kind"] as? String, "notification.received")
    }
}

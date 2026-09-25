import XCTest
@testable import ArkIntelligence

final class NotificationSweepTests: XCTestCase {
    func card(_ title: String) -> NotificationAXNode {
        NotificationAXNode(role: "AXGroup", subrole: "AXNotificationCenterAlert", children: [
            NotificationAXNode(role: "AXStaticText", identifier: "header", value: "微信"),
            NotificationAXNode(role: "AXStaticText", identifier: "title", value: title),
            NotificationAXNode(role: "AXStaticText", identifier: "body", value: "合成消息"),
            NotificationAXNode(role: "AXStaticText", identifier: "timestamp", value: "2分钟前")
        ])
    }
    func stack() -> NotificationAXNode {
        var node = card("折叠预览")
        node.subrole = "AXNotificationCenterAlertStack"
        node.actions = ["AXPress", "Name:Show Details", "Name:Clear All"]
        return node
    }
    func page(_ cards: [NotificationAXNode]) -> NotificationAXNode {
        NotificationAXNode(children: [NotificationAXNode(role: "AXScrollArea", identifier: "AXNotificationListItems", actions: ["AXScrollDownByPage"], children: cards)])
    }

    func testOnlyConfirmedStacksMayBePressed() {
        XCTAssertEqual(NotificationNavigation.expansion(page([stack()]))?.action, "AXPress")
        var single = stack()
        single.actions = ["AXPress", "Name:Show Details", "Name:Close"]
        XCTAssertNil(NotificationNavigation.expansion(page([single])))
        single.actions += ["Name:Clear All"]
        XCTAssertNil(NotificationNavigation.expansion(page([single])))
        var expanded = stack(); expanded.expanded = true
        XCTAssertNil(NotificationNavigation.expansion(page([expanded])))
    }

    func testTextAndWidgetControlsCannotTriggerActions() {
        let malicious = NotificationAXNode(role: "AXStaticText", title: "展开", actions: ["AXPress"])
        XCTAssertNil(NotificationNavigation.expansion(page([malicious])))
        let widget = NotificationAXNode(role: "AXScrollArea", identifier: "widget-weather", actions: ["AXScrollDownByPage"])
        XCTAssertNil(NotificationNavigation.scroll(widget))
    }

    func testMirroredChineseStacksWithExtraActionsAndSelectorSuffix() {
        var node = card("合成预览")
        node.subrole = ""
        node.label = "测试应用，合成预览，已叠放，来自iPhone"
        node.actions = ["AXPress", "Name:显示详细信息, Target:showDetails:", "Name:回复, Target:reply:", "Name:全部清除, Target:clearAll:"]
        XCTAssertEqual(NotificationNavigation.expansion(page([node]))?.action, "AXPress")
        XCTAssertNil(NotificationNavigation.expansion(node))
        node.actions.append("Name:关闭, Target:close:")
        XCTAssertNil(NotificationNavigation.expansion(page([node])))
    }

    func testObservedBannerStackWithNewlineActionMetadata() async throws {
        var node = stack()
        node.subrole = "AXNotificationCenterBannerStack"
        node.actions = ["AXPress", "Name:显示详细信息\nTarget:0x0\nSelector:(null)", "Name:回复\nTarget:0x0\nSelector:(null)", "Name:全部清除\nTarget:0x0\nSelector:(null)"]
        XCTAssertEqual(NotificationNavigation.normalized(node.actions[1]), "显示详细信息")
        XCTAssertEqual(NotificationNavigation.expansion(page([node]))?.action, "AXPress")
        let driver = FakeSweepDriver(pages: [page([node]), page([card("展开后消息")])])
        let captured = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(captured.events.map(\.title), ["展开后消息"])
        XCTAssertTrue(captured.warning.contains("自动展开 1 次"))
        node.actions.append("Name:关闭\nTarget:0x0\nSelector:(null)")
        XCTAssertNil(NotificationNavigation.expansion(page([node])))
    }

    func testCollapsedPreviewIsNotAnExtraNotification() {
        XCTAssertTrue(NotificationCardParser.parse(page([stack()]), now: Date()).isEmpty)
    }

    func testScrollRevalidationAllowsLiveContentButRejectsOtherAreas() {
        let original = page([card("原内容")])
        let command = NotificationNavigation.scroll(original)!
        XCTAssertTrue(NotificationNavigation.matchesTarget(page([card("更新内容")]).children[0], command: command))
        XCTAssertFalse(NotificationNavigation.matchesTarget(NotificationAXNode(role: "AXScrollArea", identifier: "weather"), command: command))
        let stackCommand = NotificationNavigation.expansion(page([stack()]))!
        XCTAssertFalse(NotificationNavigation.matchesTarget(card("单条消息"), command: stackCommand))
    }

    func testExpandThenScrollCollectsAndDeduplicatesPages() async throws {
        let driver = FakeSweepDriver(pages: [page([stack()]), page([card("一"),card("二")]), page([card("二"),card("三")])])
        let result = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(result.events.map(\.title), ["一", "二", "三"])
        XCTAssertEqual(driver.actions.first, "AXPress")
        XCTAssertTrue(result.warning.contains("自动展开 1 次"))
        XCTAssertLessThan(driver.actions.count, 10)
    }

    func testNonChangingExpansionIsNotPressedForever() async throws {
        let driver = FakeSweepDriver(pages: [page([stack()])])
        let result = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(driver.actions.filter { $0 == "AXPress" }.count, 1)
        XCTAssertTrue(result.warning.contains("没有变化"))
    }

    func testFailedExpansionKeepsOtherReadableCards() async throws {
        let driver = FakeSweepDriver(pages: [page([stack(), card("可读")])], failExpansion: true)
        let result = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(result.events.map(\.title), ["可读"])
        XCTAssertTrue(result.warning.contains("未能自动展开"))
    }

    func testFailedPageFallsBackToScrollbar() async throws {
        let driver = FakeSweepDriver(pages: [page([card("一")]), page([card("二")])])
        driver.failPage = true
        let captured = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(captured.events.map(\.title), ["一", "二"])
        XCTAssertEqual(Array(driver.actions.prefix(3)), ["scroll-wheel-down", "AXScrollDownByPage", "scroll-bar-down"])
        XCTAssertTrue(captured.warning.contains("滚动 1 次"))
    }

    func testSuccessfulButStationaryPageUsesFallback() async throws {
        let driver = FakeSweepDriver(pages: [page([card("一")]), page([card("二")])])
        driver.stationaryPage = true
        let captured = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(captured.events.count, 2)
        XCTAssertTrue(driver.actions.contains("scroll-bar-down"))
        XCTAssertTrue(captured.warning.contains("无法确认到达底部"))
    }

    func testPositionChangeWithoutTextChangeStillScrolls() async throws {
        let driver = FakeSweepDriver(pages: [page([card("相同")]), page([card("相同")]), page([card("末页")])])
        let captured = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(captured.events.map(\.title), ["相同", "末页"])
        XCTAssertTrue(captured.warning.contains("滚动 2 次"))
    }

    func testExplicitBottomDoesNotRequestAnotherScroll() async throws {
        var bottom = page([card("末页")]); bottom.children[0].scrollAtBottom = true
        let driver = FakeSweepDriver(pages: [bottom])
        let captured = try await NotificationSweep.collect(driver: driver)
        XCTAssertTrue(driver.actions.isEmpty)
        XCTAssertTrue(captured.warning.contains("位置确认已到"))
    }

    func testWheelWorksWithoutScrollbarOrAXPageAction() async throws {
        var first = page([card("一")]), last = page([card("二")])
        first.children[0].actions = []; last.children[0].actions = []
        let driver = FakeSweepDriver(pages: [first, last]); driver.failWheel = false
        let captured = try await NotificationSweep.collect(driver: driver)
        XCTAssertEqual(captured.events.map(\.title), ["一", "二"])
        XCTAssertEqual(driver.actions.first, "scroll-wheel-down")
        XCTAssertTrue(captured.warning.contains("滚动 1 次"))
    }

    func testWheelGestureIsBoundedAndRejectsInvalidGeometry() {
        let frame = CGRect(x: 900, y: 40, width: 350, height: 500)
        let gesture = NotificationNavigation.wheelGesture(in: frame, up: false)!
        XCTAssertTrue(frame.contains(gesture.point))
        XCTAssertEqual(gesture.delta, -300)
        XCTAssertNil(NotificationNavigation.wheelGesture(in: .zero, up: false))
        XCTAssertNil(NotificationNavigation.wheelGesture(in: CGRect(x: Double.infinity, y: 0, width: 30, height: 30), up: false))
    }

    func testWheelLandingUsesVisibleCardInsteadOfBlankWindowCenter() {
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let card = CGRect(x: 900, y: 700, width: 280, height: 160)
        let point = NotificationNavigation.wheelLanding(card: card, viewport: viewport)!
        XCTAssertEqual(point, CGPoint(x: 1040, y: 750))
        XCTAssertNil(NotificationNavigation.wheelLanding(card: CGRect(x: 900, y: 900, width: 280, height: 100), viewport: viewport))
    }

    func testBudgetStopsEndlessChangingPages() async throws {
        let driver = FakeSweepDriver(pages: (0..<20).map { page([card(String($0))]) })
        let result = try await NotificationSweep.collect(driver: driver, maxSteps: 3)
        XCTAssertEqual(result.events.count, 3)
        XCTAssertTrue(result.warning.contains("操作次数上限"))
    }
}

private final class FakeSweepDriver: NotificationSweepDriver {
    let pages: [NotificationAXNode]
    let failExpansion: Bool
    var failWheel = true
    var failPage = false
    var stationaryPage = false
    var index = 0
    var actions: [String] = []
    init(pages: [NotificationAXNode], failExpansion: Bool = false) { self.pages = pages; self.failExpansion = failExpansion }
    func readPage(deadline: Date) throws -> NotificationAXNode {
        var result = pages[index]
        result.children[0].scrollPosition = Double(index)
        return result
    }
    func perform(_ command: NotificationNavigation.Command) -> Bool {
        if command.action == "set-top" || command.action == "scroll-wheel-up" { return false }
        actions.append(command.action)
        if command.action.hasPrefix("scroll-wheel") && failWheel { return false }
        if command.action == "AXScrollDownByPage" && failPage { return false }
        if command.action == "AXScrollDownByPage" && stationaryPage { return true }
        if command.action == "AXPress" && failExpansion { return false }
        index = min(index + 1, pages.count - 1)
        return true
    }
    func settle() async throws { try Task.checkCancellation() }
}

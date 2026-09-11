import XCTest
@testable import ArkIntelligence

final class ProtocolTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object(["verified": .bool(true), "count": .number(2)])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testChatEventDecodesToolFields() throws {
        let data = #"{"event":"approval_required","run_id":"r","call_id":"c","action_id":"calendar.create_event","digest":"d","preview":{"summary":"新建日程"}}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: data)
        XCTAssertEqual(event.runID, "r")
        XCTAssertEqual(event.callID, "c")
        XCTAssertEqual(event.preview?["summary"], .string("新建日程"))
    }

    func testProgressEventDecodesStage() throws {
        let data = #"{"event":"progress","run_id":"r","stage":"waiting_model","content":"正在等待本地 9B 模型"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: data)
        XCTAssertEqual(event.stage, "waiting_model")
        XCTAssertEqual(event.content, "正在等待本地 9B 模型")
    }

    @MainActor
    func testChatAcceptsAnotherMessageWhileRunsAreActive() async {
        let viewModel = ChatViewModel(repository: MockChatRepository(), memoryRepository: MockMemoryRepository())
        viewModel.draft = "第一条"
        await viewModel.send()
        viewModel.draft = "第二条"
        await viewModel.send()
        XCTAssertEqual(viewModel.activeRunCount, 2)
        XCTAssertEqual(viewModel.messages.filter { $0.role == .user }.count, 2)
    }
}

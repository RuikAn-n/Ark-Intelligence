import XCTest
@testable import ArkIntelligence

@MainActor
private final class ExternalRepository: ChatRepository {
    var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?
    var approvals: [Bool] = []
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func externalRuns() async throws -> [ExternalRun] { [ExternalRun(id: "external", message: "测试提醒", status: "waiting_approval")] }
    func streamExternalRun(_ id: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(ChatStreamEvent(event: "tool_started", runID: id, callID: "call", actionID: "reminders.create_reminder"))
            continuation.yield(ChatStreamEvent(event: "approval_required", runID: id, callID: "call", digest: "digest", preview: ["summary": .string("测试提醒")]))
        }
    }
    func submitApproval(runID: String, callID: String, digest: String, approved: Bool) async throws {
        approvals.append(approved)
        continuation?.yield(ChatStreamEvent(event: "answer", runID: runID, content: "verified"))
        continuation?.yield(ChatStreamEvent(event: "done", runID: runID))
        continuation?.finish()
    }
    func cancel(runID: String) async throws {}
    func restoreHistory(_ messages: [ChatMessage]) {}
    func endSession() async throws -> SessionEndResponse { SessionEndResponse(status: "ok") }
}

final class HermesBridgeTests: XCTestCase {
    func testHermesSkillMetadataDecodesWithEmptyActions() throws {
        let data = Data(#"{"id":"hermes.skill.docx","version":"1.0.0","name":"docx","description":"Word documents","icon":"books.vertical","isEnabled":true,"available":true,"required_permissions":[],"permission_status":{},"actions":[],"source":"hermes","category":"productivity"}"#.utf8)
        let skill = try JSONDecoder().decode(Skill.self, from: data)
        XCTAssertEqual(skill.source, "hermes")
        XCTAssertEqual(skill.category, "productivity")
        XCTAssertTrue(skill.actions.isEmpty)
    }

    @MainActor
    func testExternalApprovalAppearsWithoutResubmittingChat() async throws {
        let repository = ExternalRepository()
        let model = ChatViewModel(repository: repository, memoryRepository: MockMemoryRepository())
        let monitor = Task { await model.monitorExternalRuns() }
        defer { monitor.cancel(); repository.continuation?.finish() }
        for _ in 0..<100 where model.toolActivities.first?.state != .waitingApproval {
            try await Task.sleep(for: .milliseconds(5))
        }
        let activity = try XCTUnwrap(model.toolActivities.first)
        XCTAssertEqual(activity.state, .waitingApproval)
        XCTAssertEqual(model.activeRunCount, 1)
        XCTAssertTrue(model.messages.isEmpty)
        await model.resolveApproval(for: activity, approved: true)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(repository.approvals, [true])
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.messages.isEmpty, "External results must not become this conversation's assistant messages")
    }
}

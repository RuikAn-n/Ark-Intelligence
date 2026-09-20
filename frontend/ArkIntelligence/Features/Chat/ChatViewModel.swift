import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var currentRetrievedMemories: [MemoryItem] = []
    @Published private(set) var state: GenerationState = .idle
    @Published private(set) var isEndingSession = false
    @Published private(set) var sessionError: String?
    @Published private(set) var toolActivities: [ToolActivity] = []
    @Published private(set) var backgroundRuns: [BackgroundRun] = []
    @Published var draft = ""

    private let repository: ChatRepository
    private let conversationRepository: ConversationRepository?
    private var activeConversationID: UUID?
    private var streamTasks: [UUID: Task<Void, Never>] = [:]

    var activeRunCount: Int { backgroundRuns.count(where: \.isActive) }
    var isBusy: Bool { activeRunCount > 0 }

    init(repository: ChatRepository, memoryRepository: MemoryRepository, conversationRepository: ConversationRepository? = nil) {
        self.repository = repository
        self.conversationRepository = conversationRepository
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isEndingSession else { return }
        draft = ""
        submit(text)
    }

    func sendVoice(_ text: String, onEvent: @escaping (ChatStreamEvent) -> Void) {
        guard !isEndingSession, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submit(text, voice: true, onEvent: onEvent)
    }

    private func submit(_ text: String, voice: Bool = false, onEvent: ((ChatStreamEvent) -> Void)? = nil) {
        sessionError = nil
        messages.append(ChatMessage(id: UUID(), role: .user, content: text, timestamp: .now, modelInfo: nil, memories: []))

        let localID = UUID()
        backgroundRuns.append(BackgroundRun(id: localID, runID: nil, request: text, startedAt: .now, stage: "queued", detail: "正在提交本地任务", isActive: true, error: nil))
        pruneHistory()
        state = .thinking
        let task = Task { [weak self] in
            guard let self else { return }
            await self.consume(text: text, localID: localID, voice: voice, onEvent: onEvent)
        }
        streamTasks[localID] = task
    }

    func monitorExternalRuns() async {
        while !Task.isCancelled {
            do {
                for run in try await repository.externalRuns() {
                    let existing = backgroundRuns.first(where: { $0.runID == run.id })
                    if let existing, streamTasks[existing.id] != nil { continue }
                    let localID = existing?.id ?? UUID()
                    if existing == nil {
                        backgroundRuns.append(BackgroundRun(id: localID, runID: run.id, request: "Hermes · " + run.message, startedAt: .now, stage: run.status, detail: "来自 Hermes 的 Skill 请求", isActive: true, error: nil))
                    } else {
                        updateRun(localID) { $0.isActive = true; $0.error = nil }
                    }
                    toolActivities.removeAll { $0.runID == run.id }
                    streamTasks[localID] = Task { [weak self] in
                        await self?.consume(text: run.message, localID: localID, voice: false, onEvent: nil, externalID: run.id)
                    }
                    pruneHistory()
                }
            } catch { /* Backend reconnect is retried on the next bounded poll. */ }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func consume(text: String, localID: UUID, voice: Bool, onEvent: ((ChatStreamEvent) -> Void)?, externalID: String? = nil) async {
        var assistantID: UUID?
        var retrievedMemories: [MemoryItem] = []
        var receivedTerminalEvent = false
        defer {
            streamTasks.removeValue(forKey: localID)
            if !receivedTerminalEvent { finishRun(localID, error: nil) }
            refreshGenerationState()
        }

        do {
            let stream = externalID.map { repository.streamExternalRun($0) } ?? (voice ? repository.streamVoiceMessage(text) : repository.streamMessage(text))
            for try await event in stream {
                onEvent?(event)
                if let runID = event.runID { updateRun(localID) { $0.runID = runID } }
                switch event.event {
                case "memory":
                    retrievedMemories = (event.items ?? []).map {
                        MemoryItem(id: $0.id, content: $0.content, category: $0.category, source: $0.source, createdAt: .now, updatedAt: .now, isDeleted: false)
                    }
                    currentRetrievedMemories = retrievedMemories
                    if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].memories = retrievedMemories
                    }
                case "ack":
                    updateRun(localID) { $0.detail = event.content ?? "请求已接收" }
                case "progress":
                    updateRun(localID) {
                        $0.stage = event.stage ?? $0.stage
                        $0.detail = event.content ?? $0.detail
                    }
                case "feedback":
                    if let content = event.content, !content.isEmpty {
                        messages.append(ChatMessage(id: UUID(), role: .summarizer, content: content, timestamp: .now, modelInfo: ModelInfo(modelName: event.model ?? "Assistant 4B", modelType: .summarizer4B), memories: []))
                    }
                case "token":
                    guard let content = event.content, !content.isEmpty else { continue }
                    if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].content += content
                    } else {
                        let id = UUID()
                        assistantID = id
                        messages.append(ChatMessage(id: id, role: .assistant, content: content, timestamp: .now, modelInfo: ModelInfo(modelName: event.model ?? "Assistant 9B", modelType: .assistant9B), memories: retrievedMemories))
                    }
                    state = .streaming
                case "answer":
                    if externalID != nil {
                        updateRun(localID) { $0.detail = event.content ?? "Hermes 请求已完成" }
                        continue
                    }
                    if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }), let content = event.content {
                        messages[index].content = content
                    }
                    if assistantID == nil, let content = event.content, !content.isEmpty {
                        let id = UUID()
                        assistantID = id
                        messages.append(ChatMessage(id: id, role: .assistant, content: content, timestamp: .now, modelInfo: ModelInfo(modelName: event.model ?? "Assistant 9B", modelType: .assistant9B), memories: retrievedMemories))
                    }
                case "done":
                    receivedTerminalEvent = true
                    finishRun(localID, error: nil)
                case "tool_started":
                    if let id = event.callID {
                        let owningRunID = event.runID ?? runID(for: localID) ?? ""
                        toolActivities.append(ToolActivity(id: id, runID: owningRunID, actionID: event.actionID ?? "unknown", state: .preparing, detail: event.content ?? "正在准备", preview: nil, digest: nil))
                        pruneTools()
                    }
                case "approval_required":
                    if let id = event.callID, let index = toolActivities.firstIndex(where: { $0.id == id }) {
                        toolActivities[index].state = .waitingApproval
                        toolActivities[index].preview = event.preview
                        toolActivities[index].digest = event.digest
                        toolActivities[index].detail = "等待确认；聊天仍可继续"
                    }
                case "tool_finished":
                    updateTool(event, state: .succeeded, fallback: "执行成功")
                case "tool_failed":
                    updateTool(event, state: .failed, fallback: "执行失败")
                case "task_state":
                    updateRun(localID) { $0.stage = event.content ?? $0.stage }
                    if event.content == "executing", let runID = event.runID {
                        for index in toolActivities.indices where toolActivities[index].runID == runID && toolActivities[index].state == .waitingApproval {
                            toolActivities[index].state = .executing
                            toolActivities[index].detail = "正在后台执行"
                        }
                    }
                case "error":
                    receivedTerminalEvent = true
                    let message = event.error ?? "后端返回未知错误"
                    finishRun(localID, error: message)
                    messages.append(ChatMessage(id: UUID(), role: .system, content: "后台任务「\(String(text.prefix(36)))」失败：\(message)", timestamp: .now, modelInfo: nil, memories: []))
                default:
                    continue
                }
            }
        } catch is CancellationError {
            receivedTerminalEvent = true
            finishRun(localID, error: "任务已取消")
        } catch {
            onEvent?(ChatStreamEvent(event: "error", error: error.localizedDescription))
            receivedTerminalEvent = true
            finishRun(localID, error: error.localizedDescription)
            messages.append(ChatMessage(id: UUID(), role: .system, content: "后台任务「\(String(text.prefix(36)))」连接失败：\(error.localizedDescription)", timestamp: .now, modelInfo: nil, memories: []))
        }
    }

    func resolveApproval(for activity: ToolActivity, approved: Bool) async {
        guard !activity.runID.isEmpty, let digest = activity.digest else { return }
        do {
            try await repository.submitApproval(runID: activity.runID, callID: activity.id, digest: digest, approved: approved)
            if let index = toolActivities.firstIndex(where: { $0.id == activity.id }) {
                toolActivities[index].detail = approved ? "已确认，等待后台执行" : "已拒绝"
                if !approved { toolActivities[index].state = .failed }
            }
        } catch { sessionError = error.localizedDescription }
    }

    func cancel(_ run: BackgroundRun) async {
        guard let runID = run.runID else { return }
        do {
            try await repository.cancel(runID: runID)
            updateRun(run.id) { $0.detail = "正在取消" }
        } catch { sessionError = error.localizedDescription }
    }

    func endSession() async {
        guard !messages.isEmpty, activeRunCount == 0, !isEndingSession else { return }
        isEndingSession = true
        sessionError = nil
        let snapshot = messages
        defer { isEndingSession = false }
        do {
            _ = try await repository.endSession()
            if let conversationRepository {
                let record = makeConversationRecord(from: snapshot)
                activeConversationID = record.id
                try await conversationRepository.saveConversation(record)
            }
            messages = [ChatMessage(id: UUID(), role: .system, content: "本次对话已结束，后端已完成会话总结。", timestamp: .now, modelInfo: nil, memories: [])]
            currentRetrievedMemories = []
            toolActivities = []
            backgroundRuns = []
            state = .idle
        } catch {
            sessionError = error.localizedDescription
        }
    }

    func restoreConversation(_ conversation: ConversationRecord) {
        guard activeRunCount == 0 else {
            sessionError = "请等待或取消后台任务后再恢复历史对话。"
            return
        }
        activeConversationID = conversation.id
        messages = conversation.messages
        currentRetrievedMemories = []
        toolActivities = []
        backgroundRuns = []
        draft = ""
        state = .completed
        sessionError = nil
        repository.restoreHistory(conversation.messages)
    }

    private func updateRun(_ id: UUID, change: (inout BackgroundRun) -> Void) {
        guard let index = backgroundRuns.firstIndex(where: { $0.id == id }) else { return }
        change(&backgroundRuns[index])
    }

    private func runID(for id: UUID) -> String? {
        backgroundRuns.first(where: { $0.id == id })?.runID
    }

    private func finishRun(_ id: UUID, error: String?) {
        updateRun(id) {
            $0.isActive = false
            $0.error = error
            $0.stage = error == nil ? "succeeded" : "failed"
            $0.detail = error ?? "任务已完成"
        }
        refreshGenerationState()
    }

    private func refreshGenerationState() {
        if activeRunCount > 0 {
            state = .streaming
        } else if let message = backgroundRuns.last(where: { $0.error != nil })?.error {
            state = .failed(message)
        } else {
            state = messages.isEmpty ? .idle : .completed
        }
    }

    private func updateTool(_ event: ChatStreamEvent, state: ToolActivityState, fallback: String) {
        guard let id = event.callID, let index = toolActivities.firstIndex(where: { $0.id == id }) else { return }
        toolActivities[index].state = state
        toolActivities[index].detail = state == .succeeded ? "执行成功，结果已返回给模型" : (event.content ?? fallback)
    }

    private func pruneHistory() {
        guard backgroundRuns.count > 20 else { return }
        let active = backgroundRuns.filter(\.isActive)
        let finished = backgroundRuns.filter { !$0.isActive }.suffix(max(0, 20 - active.count))
        backgroundRuns = Array(finished) + active
    }

    private func pruneTools() {
        guard toolActivities.count > 60 else { return }
        let pending = toolActivities.filter { $0.state == .waitingApproval || $0.state == .executing || $0.state == .preparing }
        let finished = toolActivities.filter { !pending.contains($0) }.suffix(max(0, 60 - pending.count))
        toolActivities = Array(finished) + pending
    }

    private func makeConversationRecord(from messages: [ChatMessage]) -> ConversationRecord {
        let validMessages = messages.filter { $0.role != .system }
        let toolMessages = toolActivities.map { activity in
            ChatMessage(id: UUID(), role: .system, content: "工具 \(activity.actionID)：\(activity.detail)", timestamp: .now, modelInfo: nil, memories: [])
        }
        let recordMessages = validMessages + toolMessages
        let titleSource = validMessages.first(where: { $0.role == .user })?.content ?? validMessages.first?.content ?? "新对话"
        let trimmedTitle = titleSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? "新对话" : String(trimmedTitle.prefix(40))
        let updatedAt = validMessages.last?.timestamp ?? .now
        let createdAt = validMessages.first?.timestamp ?? .now
        return ConversationRecord(id: activeConversationID ?? UUID(), title: title, createdAt: createdAt, updatedAt: updatedAt, messageCount: recordMessages.count, messages: recordMessages)
    }
}

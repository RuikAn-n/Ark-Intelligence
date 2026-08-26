import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var currentRetrievedMemories: [MemoryItem] = []
    @Published private(set) var state: GenerationState = .idle
    @Published private(set) var isEndingSession = false
    @Published private(set) var sessionError: String?
    @Published var draft = ""
    private let repository: ChatRepository

    init(repository: ChatRepository, memoryRepository: MemoryRepository) {
        self.repository = repository
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .thinking else { return }
        draft = ""
        currentRetrievedMemories = []
        messages.append(ChatMessage(id: UUID(), role: .user, content: text, timestamp: .now, modelInfo: nil, memories: []))
        state = .thinking
        do {
            var assistantID: UUID?
            var retrievedMemories: [MemoryItem] = []
            for try await event in repository.streamMessage(text) {
                switch event.event {
                case "memory":
                    retrievedMemories = (event.items ?? []).map {
                            MemoryItem(id: $0.id, content: $0.content, category: $0.category, source: $0.source, createdAt: .now, updatedAt: .now, isDeleted: false)
                    }
                    currentRetrievedMemories = retrievedMemories
                    if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].memories = retrievedMemories
                    }
                case "ack", "feedback":
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
                    if assistantID == nil, let content = event.content, !content.isEmpty {
                        assistantID = UUID()
                        messages.append(ChatMessage(id: assistantID!, role: .assistant, content: content, timestamp: .now, modelInfo: ModelInfo(modelName: event.model ?? "Assistant 9B", modelType: .assistant9B), memories: []))
                    }
                case "done":
                    state = .completed
                case "error":
                    throw ChatError.backend(event.error ?? "后端返回未知错误")
                default:
                    continue
                }

            }
            state = .completed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func endSession() async {
        guard !messages.isEmpty, state != .thinking, !isEndingSession else { return }
        isEndingSession = true
        sessionError = nil
        defer { isEndingSession = false }
        do {
            _ = try await repository.endSession()
            messages = [ChatMessage(id: UUID(), role: .system, content: "本次对话已结束，后端已完成会话总结。", timestamp: .now, modelInfo: nil, memories: [])]
            currentRetrievedMemories = []
            state = .idle
        } catch {
            sessionError = error.localizedDescription
        }
    }
}

enum ChatError: LocalizedError {
    case backend(String)
    var errorDescription: String? {
        if case .backend(let message) = self { return message }
        return nil
    }
}

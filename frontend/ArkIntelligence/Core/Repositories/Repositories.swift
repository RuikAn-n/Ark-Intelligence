import Foundation

@MainActor
protocol ChatRepository {
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
    func streamVoiceMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
    func endSession() async throws -> SessionEndResponse
    func submitApproval(runID: String, callID: String, digest: String, approved: Bool) async throws
    func cancel(runID: String) async throws
    func restoreHistory(_ messages: [ChatMessage])
}

extension ChatRepository {
    func streamVoiceMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> { streamMessage(message) }
}

@MainActor
protocol MemoryRepository {
    func fetchMemories() async throws -> [MemoryItem]
    func createMemory(_ memory: MemoryItem) async throws -> MemoryItem
    func updateMemory(_ memory: MemoryItem) async throws
    func softDeleteMemory(_ memory: MemoryItem) async throws
    func permanentlyDeleteMemory(_ memory: MemoryItem) async throws
}

@MainActor
protocol ConversationRepository {
    func fetchConversations() async throws -> [ConversationRecord]
    func saveConversation(_ conversation: ConversationRecord) async throws
    func deleteConversation(id: UUID) async throws
}

@MainActor
protocol SkillRepository {
    func fetchSkills() async throws -> [Skill]
    func enableSkill(_ skill: Skill) async throws
    func disableSkill(_ skill: Skill) async throws
}

@MainActor
protocol VoiceService {
    func startListening() async
    func stopListening() async
    func speak(_ text: String) async
}

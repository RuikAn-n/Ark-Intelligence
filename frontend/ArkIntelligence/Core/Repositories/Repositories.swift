import Foundation

@MainActor
protocol ChatRepository {
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

@MainActor
protocol MemoryRepository {
    func fetchMemories() async throws -> [MemoryItem]
    func createMemory(_ memory: MemoryItem) async throws
    func updateMemory(_ memory: MemoryItem) async throws
    func softDeleteMemory(_ memory: MemoryItem) async throws
    func permanentlyDeleteMemory(_ memory: MemoryItem) async throws
}

@MainActor
protocol ConversationRepository {
    func fetchConversations() async throws -> [ConversationRecord]
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

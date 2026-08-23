import Foundation

struct MockChatRepository: ChatRepository {
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ChatStreamEvent(event: "ack", requestID: nil, model: "Assistant 4B", stage: nil, content: "我了解了，你希望我处理这个问题。", error: nil))
            continuation.yield(ChatStreamEvent(event: "token", requestID: nil, model: "Assistant 9B", stage: nil, content: "这是一个本地 Mock 回答。你刚才说的是：**\(message)**", error: nil))
            continuation.yield(ChatStreamEvent(event: "done", requestID: nil, model: nil, stage: nil, content: nil, error: nil))
            continuation.finish()
        }
    }
}

@MainActor
final class MockMemoryRepository: MemoryRepository, ObservableObject {
    private var memories = MockData.memories

    func fetchMemories() async throws -> [MemoryItem] { memories }
    func createMemory(_ memory: MemoryItem) async throws { memories.insert(memory, at: 0) }
    func updateMemory(_ memory: MemoryItem) async throws {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[index] = memory
    }
    func softDeleteMemory(_ memory: MemoryItem) async throws { var item = memory; item.isDeleted = true; try await updateMemory(item) }
    func permanentlyDeleteMemory(_ memory: MemoryItem) async throws { memories.removeAll { $0.id == memory.id } }
}

struct MockConversationRepository: ConversationRepository {
    func fetchConversations() async throws -> [ConversationRecord] { MockData.conversations }
}

@MainActor
final class MockSkillRepository: SkillRepository, ObservableObject {
    private var skills = MockData.skills
    func fetchSkills() async throws -> [Skill] { skills }
    func enableSkill(_ skill: Skill) async throws { try await set(skill, enabled: true) }
    func disableSkill(_ skill: Skill) async throws { try await set(skill, enabled: false) }
    private func set(_ skill: Skill, enabled: Bool) async throws {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[index].isEnabled = enabled
    }
}

struct MockVoiceService: VoiceService {
    func startListening() async {}
    func stopListening() async {}
    func speak(_ text: String) async {}
}

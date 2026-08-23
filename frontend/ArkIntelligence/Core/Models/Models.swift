import Foundation
import SwiftUI

enum SidebarDestination: Hashable {
    case chat, voice, memoryOverview, memoryManager, history, skills
}

enum MessageRole: String, Codable {
    case user, summarizer, assistant, system
}

enum ModelType: String, Codable {
    case summarizer4B, assistant9B
}

struct ModelInfo: Codable, Hashable {
    let modelName: String
    let modelType: ModelType
}

enum MemorySource: String, Codable, CaseIterable {
    case retrieval, semantic, keyword, manual, system
}

enum MemoryCategory: String, Codable, CaseIterable, Identifiable {
    case project = "Project"
    case preference = "Preference"
    case goal = "Goal"
    case general = "General"

    var id: String { rawValue }
}

enum MemoryManagerFilter: Hashable, Identifiable {
    case all, category(MemoryCategory), deleted
    var id: String {
        switch self {
        case .all: "all"
        case .category(let category): category.rawValue
        case .deleted: "deleted"
        }
    }
}

struct MemoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    var content: String
    var category: MemoryCategory
    var source: MemorySource
    let createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    let modelInfo: ModelInfo?
    var memories: [MemoryItem]
}

struct ChatStreamEvent: Codable {
    let event: String
    let requestID: String?
    let model: String?
    let stage: Int?
    let content: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case event, model, stage, content, error
        case requestID = "request_id"
    }
}

struct ConversationRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let messages: [ChatMessage]
}

struct Skill: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let description: String
    let icon: String
    var isEnabled: Bool
}

enum VoiceState: String {
    case idle, listening, processing, speaking, unavailable
}

enum GenerationState: Equatable {
    case idle, thinking, streaming, completed, failed(String)
}

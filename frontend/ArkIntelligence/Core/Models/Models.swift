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
    case retrieval, semantic, keyword, manual, system, inferred, explicit
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
    let id: Int
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
    let runID: String?
    let eventID: Int?
    let model: String?
    let stage: String?
    let content: String?
    let error: String?
    let items: [RetrievedMemory]?
    let callID: String?
    let actionID: String?
    let digest: String?
    let preview: [String: JSONValue]?

    init(event: String, requestID: String? = nil, runID: String? = nil, eventID: Int? = nil, model: String? = nil, stage: String? = nil, content: String? = nil, error: String? = nil, items: [RetrievedMemory]? = nil, callID: String? = nil, actionID: String? = nil, digest: String? = nil, preview: [String: JSONValue]? = nil) {
        self.event = event; self.requestID = requestID; self.runID = runID; self.eventID = eventID
        self.model = model; self.stage = stage; self.content = content; self.error = error; self.items = items
        self.callID = callID; self.actionID = actionID; self.digest = digest; self.preview = preview
    }

    enum CodingKeys: String, CodingKey {
        case event, model, stage, content, error, preview, digest
        case requestID = "request_id"
        case runID = "run_id"
        case eventID = "event_id"
        case callID = "call_id"
        case actionID = "action_id"
        case items
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(format: "%g", value)
        case .bool(let value): return value ? "是" : "否"
        case .null: return "无"
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self),
                  let value = String(data: data, encoding: .utf8) else { return "" }
            return value
        }
    }
}

struct SessionEndResponse: Decodable {
    let status: String
}

struct RetrievedMemory: Codable, Hashable, Identifiable {
    let id: Int
    let content: String
    let category: MemoryCategory
    let source: MemorySource

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        content = try container.decode(String.self, forKey: .content)
        let categoryValue = try container.decodeIfPresent(String.self, forKey: .category) ?? "general"
        category = MemoryCategory(rawValue: categoryValue.capitalized) ?? .general
        source = try container.decodeIfPresent(MemorySource.self, forKey: .source) ?? .retrieval
    }

    private enum CodingKeys: String, CodingKey { case id, content, category, source }
}

struct ConversationRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let messages: [ChatMessage]
}

struct SkillAction: Codable, Hashable, Identifiable {
    let id: String
    let description: String
    let sideEffect: String
    let confirmation: String

    enum CodingKeys: String, CodingKey {
        case id, description, confirmation
        case sideEffect = "side_effect"
    }
}

struct Skill: Identifiable, Codable, Hashable {
    let id: String
    let version: String
    let name: String
    let description: String
    let icon: String
    var isEnabled: Bool
    let available: Bool
    let requiredPermissions: [String]
    let permissionStatus: [String: String]
    let actions: [SkillAction]
    var source: String? = nil
    var category: String? = nil
    var availabilityReason: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, icon, available, actions
        case isEnabled
        case requiredPermissions = "required_permissions"
        case permissionStatus = "permission_status"
        case source, category
        case availabilityReason = "availability_reason"
    }
}

enum ToolActivityState: String, Codable {
    case preparing, waitingApproval, executing, succeeded, failed
}

struct ToolActivity: Identifiable, Codable, Hashable {
    let id: String
    let runID: String
    var actionID: String
    var state: ToolActivityState
    var detail: String
    var preview: [String: JSONValue]?
    var digest: String?
}

struct BackgroundRun: Identifiable, Hashable {
    let id: UUID
    var runID: String?
    let request: String
    let startedAt: Date
    var stage: String
    var detail: String
    var isActive: Bool
    var error: String?
}

enum VoiceState: String {
    case idle, loading, armed, listening, processing, speaking, unavailable
}

enum GenerationState: Equatable {
    case idle, thinking, streaming, completed, failed(String)
}

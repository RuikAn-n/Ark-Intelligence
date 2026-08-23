import Foundation

enum APIEndpoint {
    case chat, chatStream, memories, memory(id: UUID), conversations, skills

    var path: String {
        switch self {
        case .chat: "/chat"
        case .chatStream: "/chat/stream"
        case .memories: "/memories"
        case .memory(let id): "/memories/\(id.uuidString)"
        case .conversations: "/conversations"
        case .skills: "/skills"
        }
    }
}

import Foundation

enum APIEndpoint {
    case chat, chatStream, sessionEnd, memories, memory(id: Int), conversations, skills

    var path: String {
        switch self {
        case .chat: "/chat"
        case .chatStream: "/chat/stream"
        case .sessionEnd: "/session/end"
        case .memories: "/memories"
        case .memory(let id): "/memories/\(id)"
        case .conversations: "/conversations"
        case .skills: "/skills"
        }
    }
}

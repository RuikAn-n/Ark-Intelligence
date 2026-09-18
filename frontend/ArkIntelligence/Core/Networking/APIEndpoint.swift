import Foundation

enum APIEndpoint {
    case chat, chatStream, sessionEnd, memories, memory(id: Int), conversations, skills
    case skill(id: String), runs, run(id: String), runEvents(id: String), runApproval(id: String), runCancel(id: String), sessionsEnd, externalRuns

    var path: String {
        switch self {
        case .chat: "/chat"
        case .chatStream: "/chat/stream"
        case .sessionEnd: "/session/end"
        case .memories: "/memories"
        case .memory(let id): "/memories/\(id)"
        case .conversations: "/conversations"
        case .skills: "/skills"
        case .skill(let id): "/skills/\(id)"
        case .runs: "/runs"
        case .externalRuns: "/integrations/hermes/runs"
        case .run(let id): "/runs/\(id)"
        case .runEvents(let id): "/runs/\(id)/events"
        case .runApproval(let id): "/runs/\(id)/approvals"
        case .runCancel(let id): "/runs/\(id)/cancel"
        case .sessionsEnd: "/sessions/end"
        }
    }
}

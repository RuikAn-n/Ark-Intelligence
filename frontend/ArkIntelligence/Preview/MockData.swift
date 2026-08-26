import Foundation

enum MockData {
    static let memories: [MemoryItem] = [
        MemoryItem(id: 1, content: "正在开发 Ark Intelligence 本地 AI 助手。", category: .project, source: .retrieval, createdAt: .now.addingTimeInterval(-86400 * 8), updatedAt: .now, isDeleted: false),
        MemoryItem(id: 2, content: "偏好使用 SwiftUI 开发 macOS 客户端。", category: .preference, source: .semantic, createdAt: .now.addingTimeInterval(-86400 * 5), updatedAt: .now, isDeleted: false),
        MemoryItem(id: 3, content: "希望打造开箱即用的 AI 助手。", category: .goal, source: .manual, createdAt: .now.addingTimeInterval(-86400 * 2), updatedAt: .now, isDeleted: false)
    ]

    static let conversations: [ConversationRecord] = [
        ConversationRecord(id: UUID(), title: "本地 AI 助手架构设计", createdAt: .now.addingTimeInterval(-3600), updatedAt: .now.addingTimeInterval(-1800), messageCount: 6, messages: []),
        ConversationRecord(id: UUID(), title: "SwiftUI 开发计划", createdAt: .now.addingTimeInterval(-86400), updatedAt: .now.addingTimeInterval(-86400 + 3600), messageCount: 4, messages: [])
    ]

    static let skills: [Skill] = [
        Skill(id: UUID(), name: "Music Generator", description: "MIDI 音乐生成", icon: "music.note", isEnabled: true),
        Skill(id: UUID(), name: "File Analyzer", description: "文件分析", icon: "folder", isEnabled: false)
    ]
}

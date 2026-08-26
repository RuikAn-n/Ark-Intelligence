import Foundation

@MainActor
final class AppState: ObservableObject {
    let chatViewModel: ChatViewModel
    let memoryViewModel: MemoryViewModel
    let historyViewModel: HistoryViewModel
    let skillViewModel: SkillViewModel
    let voiceViewModel: VoiceViewModel

    init() {
        let memories = MockMemoryRepository()
        let apiURL = URL(string: ProcessInfo.processInfo.environment["ARK_API_URL"] ?? "http://127.0.0.1:8000")!
        chatViewModel = ChatViewModel(repository: LiveChatRepository(baseURL: apiURL), memoryRepository: memories)
        memoryViewModel = MemoryViewModel(repository: LiveMemoryRepository(baseURL: apiURL))
        historyViewModel = HistoryViewModel(repository: MockConversationRepository())
        skillViewModel = SkillViewModel(repository: MockSkillRepository())
        voiceViewModel = VoiceViewModel(service: MockVoiceService())
    }
}

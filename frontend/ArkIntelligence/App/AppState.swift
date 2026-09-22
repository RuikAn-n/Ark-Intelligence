import Foundation

@MainActor
final class AppState: ObservableObject {
    let chatViewModel: ChatViewModel
    let memoryViewModel: MemoryViewModel
    let historyViewModel: HistoryViewModel
    let skillViewModel: SkillViewModel
    let voiceViewModel: VoiceViewModel
    let notificationViewModel: NotificationSummaryViewModel
    let nativeCapabilityHost: NativeCapabilityHost

    init() {
        let memories = MockMemoryRepository()
        let apiURL = URL(string: ProcessInfo.processInfo.environment["ARK_API_URL"] ?? "http://127.0.0.1:8765")!
        let conversationRepository = LocalConversationRepository()
        chatViewModel = ChatViewModel(repository: LiveChatRepository(baseURL: apiURL), memoryRepository: memories, conversationRepository: conversationRepository)
        memoryViewModel = MemoryViewModel(repository: LiveMemoryRepository(baseURL: apiURL))
        historyViewModel = HistoryViewModel(repository: conversationRepository)
        skillViewModel = SkillViewModel(repository: LiveSkillRepository(baseURL: apiURL))
        let voiceURL = URL(string: ProcessInfo.processInfo.environment["ARK_VOICE_URL"] ?? "http://127.0.0.1:8766")!
        voiceViewModel = VoiceViewModel(service: LiveVoiceService(baseURL: voiceURL, apiURL: apiURL), chat: chatViewModel)
        notificationViewModel = NotificationSummaryViewModel(baseURL: apiURL)
        nativeCapabilityHost = NativeCapabilityHost(baseURL: apiURL)
        nativeCapabilityHost.start()
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var selection: SidebarDestination? = .chat

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("对话") {
                    Label("主对话", systemImage: "bubble.left.and.bubble.right")
                        .tag(SidebarDestination.chat)
                    Label("语音对话", systemImage: "waveform")
                        .tag(SidebarDestination.voice)
                }
                Section("记忆") {
                    Label("记忆概览", systemImage: "brain")
                        .tag(SidebarDestination.memoryOverview)
                    Label("记忆管理", systemImage: "tray.full")
                        .tag(SidebarDestination.memoryManager)
                }
                Section("历史") {
                    Label("对话记录", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarDestination.history)
                }
                Section("Skills") {
                    Label("Skill 管理", systemImage: "puzzlepiece.extension")
                        .tag(SidebarDestination.skills)
                }
            }
            .navigationTitle("Ark Intelligence")
            .listStyle(.sidebar)
        } detail: {
            switch selection ?? .chat {
            case .chat: ChatView(viewModel: appState.chatViewModel)
            case .voice: VoiceConversationView(viewModel: appState.voiceViewModel)
            case .memoryOverview: MemoryOverviewView(viewModel: appState.memoryViewModel)
            case .memoryManager: MemoryManagerView(viewModel: appState.memoryViewModel)
            case .history: ConversationHistoryView(viewModel: appState.historyViewModel)
            case .skills: SkillListView(viewModel: appState.skillViewModel)
            }
        }
    }
}

#Preview { ContentView(appState: AppState()) }

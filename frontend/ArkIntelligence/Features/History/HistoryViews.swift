import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let repository: ConversationRepository
    init(repository: ConversationRepository) { self.repository = repository }
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { conversations = try await repository.fetchConversations() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ConversationHistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    var body: some View {
        Group {
            if viewModel.isLoading { ProgressView() }
            else if let errorMessage = viewModel.errorMessage { ErrorStateView(message: errorMessage) }
            else if viewModel.conversations.isEmpty { EmptyStateView(title: "暂无对话记录", systemImage: "clock") }
            else {
                List(viewModel.conversations) { conversation in
                    NavigationLink(value: conversation) {
                        VStack(alignment: .leading) { Text(conversation.title); Text("\(conversation.messageCount) 条消息 · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }
                }.navigationDestination(for: ConversationRecord.self) { ConversationDetailView(conversation: $0) }
            }
        }.navigationTitle("对话记录").task { await viewModel.load() }
    }
}

struct ConversationDetailView: View {
    let conversation: ConversationRecord
    var body: some View {
        VStack(alignment: .leading) {
            Text(conversation.title).font(.title2.bold())
            Text("后端聊天记录尚未持久化，当前展示 Mock 数据。").foregroundStyle(.secondary)
            Spacer()
        }.padding(24).navigationTitle("对话详情")
    }
}

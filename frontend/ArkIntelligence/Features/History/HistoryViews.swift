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
        do {
            conversations = try await repository.fetchConversations()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteConversation(_ conversation: ConversationRecord) async {
        do {
            try await repository.deleteConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ConversationHistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    @Binding var selection: SidebarDestination?

    var body: some View {
        Group {
            if viewModel.isLoading { ProgressView() }
            else if let errorMessage = viewModel.errorMessage { ErrorStateView(message: errorMessage) }
            else if viewModel.conversations.isEmpty { EmptyStateView(title: "暂无对话记录", systemImage: "clock") }
            else {
                List(viewModel.conversations) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .font(.headline)
                        Text("\(conversation.messageCount) 条消息 · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        chatViewModel.restoreConversation(conversation)
                        selection = .chat
                    }
                    .contextMenu {
                        Button {
                            chatViewModel.restoreConversation(conversation)
                            selection = .chat
                        } label: {
                            Label("继续对话", systemImage: "arrow.right.circle")
                        }

                        Button(role: .destructive) {
                            Task { await viewModel.deleteConversation(conversation) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await viewModel.deleteConversation(conversation) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            chatViewModel.restoreConversation(conversation)
                            selection = .chat
                        } label: {
                            Label("继续", systemImage: "arrow.right.circle")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("对话记录")
        .task { await viewModel.load() }
    }
}

struct ConversationDetailView: View {
    let conversation: ConversationRecord
    @ObservedObject var chatViewModel: ChatViewModel
    let onContinue: () -> Void
    let onDelete: (ConversationRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(conversation.title)
                    .font(.title2.bold())

                Text("创建于 \(conversation.createdAt.formatted(date: .abbreviated, time: .shortened)) · 更新于 \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                ForEach(conversation.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("继续对话", systemImage: "arrow.right.circle") {
                    chatViewModel.restoreConversation(conversation)
                    onContinue()
                }
                Button("删除", systemImage: "trash") {
                    onDelete(conversation)
                }
                .tint(.red)
            }
        }
        .navigationTitle("对话详情")
    }
}

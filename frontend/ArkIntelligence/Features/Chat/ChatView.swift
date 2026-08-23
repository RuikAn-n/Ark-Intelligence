import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if viewModel.messages.isEmpty {
                        EmptyStateView(title: "开始一次对话", systemImage: "bubble.left.and.bubble.right")
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    if viewModel.state == .thinking {
                        Label("正在思考…", systemImage: "ellipsis")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    if case .failed(let message) = viewModel.state {
                        ErrorStateView(message: message).frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
            Divider()
            ChatInputView(viewModel: viewModel)
        }
        .navigationTitle("主对话")
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon).font(.headline)
            if message.role == .summarizer {
                DisclosureGroup("4B 模型分析", isExpanded: $showDetails) {
                    Text(message.content).foregroundStyle(.secondary)
                }
            } else {
                Text((try? AttributedString(markdown: message.content)) ?? AttributedString(message.content))
                    .textSelection(.enabled)
            }
            if !message.memories.isEmpty {
                DisclosureGroup("调用记忆 \(message.memories.count) 条", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.memories) { memory in
                            HStack(alignment: .top) {
                                Circle().fill(MemoryCategoryStyle.color(for: memory.category)).frame(width: 8, height: 8).padding(.top, 5)
                                VStack(alignment: .leading) {
                                    Text(memory.category.rawValue).font(.caption.bold())
                                    Text(memory.content).font(.callout)
                                }
                            }
                        }
                    }.padding(.top, 4)
                }.font(.subheadline)
            }
        }
        .padding(14)
        .frame(maxWidth: 760, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var label: String { message.role == .user ? "你" : (message.modelInfo?.modelName ?? "Ark Intelligence") }
    private var icon: String { message.role == .user ? "person" : "sparkles" }
}

struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    var body: some View {
        HStack(alignment: .bottom) {
            TextField("输入消息，Enter 发送", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.send() } }
            Button("发送", systemImage: "arrow.up.circle.fill") { Task { await viewModel.send() } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }
}

#Preview { ChatView(viewModel: ChatViewModel(repository: MockChatRepository(), memoryRepository: MockMemoryRepository())) }

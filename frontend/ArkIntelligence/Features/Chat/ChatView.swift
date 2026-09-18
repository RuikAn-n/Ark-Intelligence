import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("chat.taskPanel.visible") private var showsTaskPanel = false

    private var waitingApprovalCount: Int {
        viewModel.toolActivities.count(where: { $0.state == .waitingApproval })
    }

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
                    if let sessionError = viewModel.sessionError {
                        ErrorStateView(message: sessionError).frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
            Divider()
            ChatInputView(viewModel: viewModel)
        }
        .navigationTitle("主对话")
        .task { await viewModel.monitorExternalRuns() }
        .inspector(isPresented: $showsTaskPanel) {
            TaskPanelView(viewModel: viewModel)
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .onChange(of: waitingApprovalCount) { previous, current in
            if current > previous { showsTaskPanel = true }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsTaskPanel.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sidebar.trailing")
                        if viewModel.activeRunCount > 0 {
                            Text("\(viewModel.activeRunCount)")
                                .font(.caption.monospacedDigit().bold())
                        }
                    }
                }
                .help(showsTaskPanel ? "隐藏任务栏" : "显示任务栏")
                .accessibilityLabel(showsTaskPanel ? "隐藏任务栏" : "显示任务栏，\(viewModel.activeRunCount) 个任务运行中")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("结束对话", systemImage: "checkmark.circle") {
                    Task { await viewModel.endSession() }
                }
                .disabled(viewModel.messages.isEmpty || viewModel.activeRunCount > 0 || viewModel.isEndingSession)
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon).font(.headline)
            if message.role == .summarizer {
                VStack(alignment: .leading, spacing: 6) {
                    Text("4B 模型分析").font(.subheadline.bold()).foregroundStyle(.secondary)
                    Text(message.content)
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

    private var label: String {
        switch message.role {
        case .user: "你"
        case .system: "系统"
        default: message.modelInfo?.modelName ?? "Ark Intelligence"
        }
    }
    private var icon: String { message.role == .user ? "person" : "sparkles" }
}

struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var inputIsFocused: Bool
    var body: some View {
        HStack(alignment: .bottom) {
            ZStack(alignment: .topLeading) {
                if viewModel.draft.isEmpty {
                    Text("输入消息…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $viewModel.draft)
                    .focused($inputIsFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 42, maxHeight: 120)
            }
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Button("发送", systemImage: "arrow.up.circle.fill") { Task { await viewModel.send() } }
                .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isEndingSession)
        }
        .padding(16)
        .onAppear { inputIsFocused = true }
    }
}

#Preview { ChatView(viewModel: ChatViewModel(repository: MockChatRepository(), memoryRepository: MockMemoryRepository())) }

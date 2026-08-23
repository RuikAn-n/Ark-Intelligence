import SwiftUI

struct MemoryOverviewView: View {
    @ObservedObject var viewModel: MemoryViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("当前对话调用的记忆").font(.title2.bold())
            if viewModel.filteredMemories.isEmpty {
                EmptyStateView(title: "暂无记忆", systemImage: "brain")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.filteredMemories) { memory in MemoryCard(memory: memory) }
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("记忆概览")
        .task { await viewModel.load() }
    }
}

struct MemoryManagerView: View {
    @ObservedObject var viewModel: MemoryViewModel
    @State private var selectedMemory: MemoryItem?
    @State private var editingMemory: MemoryItem?
    @State private var showingNewMemory = false
    @State private var pendingDelete: MemoryItem?
    @State private var pendingSoftDelete: MemoryItem?

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedFilter) {
                Text("全部").tag(MemoryManagerFilter.all)
                ForEach(MemoryCategory.allCases) { category in
                    Label(category.rawValue, systemImage: "circle.fill").tag(MemoryManagerFilter.category(category))
                }
                Label("已删除", systemImage: "trash").tag(MemoryManagerFilter.deleted)
            }
            .navigationTitle("分类")
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜索记忆", text: $viewModel.searchText).textFieldStyle(.roundedBorder)
                    Button("新增", systemImage: "plus") { showingNewMemory = true }
                }.padding()
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredMemories.isEmpty {
                    EmptyStateView(title: "没有匹配的记忆", systemImage: "magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.filteredMemories, selection: $selectedMemory) { memory in
                        MemoryRow(memory: memory)
                            .contextMenu {
                                Button("修改") { editingMemory = memory }
                                Button("软删除", role: .destructive) { pendingSoftDelete = memory }
                                Button("永久删除", role: .destructive) { pendingDelete = memory }
                            }
                    }
                }
            }
            .sheet(item: $editingMemory) { memory in MemoryEditorView(memory: memory) { updated in Task { await viewModel.save(updated) } } }
            .sheet(isPresented: $showingNewMemory) {
                MemoryEditorView(memory: nil) { memory in Task { await viewModel.save(memory) } }
            }
            .alert("确定永久删除这条记忆吗？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("永久删除", role: .destructive) {
                    if let memory = pendingDelete { Task { await viewModel.permanentlyDelete(memory) } }
                    pendingDelete = nil
                }
            } message: { Text("此操作无法恢复。") }
            .alert("删除这条记忆？", isPresented: Binding(get: { pendingSoftDelete != nil }, set: { if !$0 { pendingSoftDelete = nil } })) {
                Button("取消", role: .cancel) { pendingSoftDelete = nil }
                Button("删除", role: .destructive) {
                    if let memory = pendingSoftDelete { Task { await viewModel.softDelete(memory) } }
                    pendingSoftDelete = nil
                }
            } message: { Text("这条记忆会保留在数据库中，可以用于后续恢复。") }
        }
        .navigationTitle("记忆管理")
        .task { await viewModel.load() }
    }
}

struct MemoryCard: View {
    let memory: MemoryItem
    var body: some View {
        HStack(alignment: .top) {
            Circle().fill(MemoryCategoryStyle.color(for: memory.category)).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(memory.category.rawValue).font(.caption.bold())
                Text(memory.content)
                Text(memory.source.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
        }.cardStyle()
    }
}

struct MemoryRow: View {
    let memory: MemoryItem
    var body: some View {
        Label {
            VStack(alignment: .leading) { Text(memory.content).lineLimit(1); Text(memory.category.rawValue).font(.caption).foregroundStyle(.secondary) }
        } icon: { Circle().fill(MemoryCategoryStyle.color(for: memory.category)).frame(width: 8, height: 8) }
    }
}

struct MemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var category: MemoryCategory
    let memory: MemoryItem?
    let onSave: (MemoryItem) -> Void

    init(memory: MemoryItem?, onSave: @escaping (MemoryItem) -> Void) {
        self.memory = memory; self.onSave = onSave
        _content = State(initialValue: memory?.content ?? "")
        _category = State(initialValue: memory?.category ?? .general)
    }

    var body: some View {
        Form {
            TextField("内容", text: $content, axis: .vertical).lineLimit(3...8)
            Picker("分类", selection: $category) { ForEach(MemoryCategory.allCases) { Text($0.rawValue).tag($0) } }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") {
                let now = Date()
                let item = MemoryItem(id: memory?.id ?? UUID(), content: content, category: category, source: memory?.source ?? .manual, createdAt: memory?.createdAt ?? now, updatedAt: now, isDeleted: memory?.isDeleted ?? false)
                onSave(item); dismiss()
            }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding().frame(width: 420)
    }
}

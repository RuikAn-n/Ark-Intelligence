import SwiftUI

@MainActor
final class SkillViewModel: ObservableObject {
    @Published private(set) var skills: [Skill] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let repository: SkillRepository
    init(repository: SkillRepository) { self.repository = repository }
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { skills = try await repository.fetchSkills() }
        catch { errorMessage = error.localizedDescription }
    }
    func setEnabled(_ skill: Skill, enabled: Bool) async {
        do {
            if enabled { try await repository.enableSkill(skill) } else { try await repository.disableSkill(skill) }
        } catch { errorMessage = error.localizedDescription }
        await load()
    }
}

struct SkillListView: View {
    @ObservedObject var viewModel: SkillViewModel
    var body: some View {
        Group {
            if viewModel.isLoading { ProgressView() }
            else if let errorMessage = viewModel.errorMessage { ErrorStateView(message: errorMessage) }
            else if viewModel.skills.isEmpty { EmptyStateView(title: "暂无 Skill", systemImage: "puzzlepiece") }
            else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.skills) { skill in
                            SkillCard(skill: skill) { enabled in Task { await viewModel.setEnabled(skill, enabled: enabled) } }
                        }
                    }.padding(24)
                }
            }
        }
        .navigationTitle("Skill 管理")
        .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await viewModel.load() } } }
        .task { await viewModel.load() }
    }
}

struct SkillCard: View {
    let skill: Skill
    let onToggle: @MainActor @Sendable (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: skill.icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading) {
                    HStack { Text(skill.name).font(.headline); Text("v\(skill.version)").font(.caption).foregroundStyle(.secondary) }
                    Text(skill.description).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("已启用", isOn: Binding(get: { skill.isEnabled }, set: { value in onToggle(value) })).labelsHidden()
            }
            if !skill.available {
                Label("原生执行宿主尚未连接，打开或重新启动 Ark 后刷新。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if !skill.requiredPermissions.isEmpty {
                HStack {
                    ForEach(skill.requiredPermissions, id: \.self) { permission in
                        Label("\(permission)：\(skill.permissionStatus[permission] ?? "未知")", systemImage: "lock.shield").font(.caption)
                    }
                }.foregroundStyle(.secondary)
            }
            DisclosureGroup("动作 \(skill.actions.count) 项") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(skill.actions) { action in
                        HStack(alignment: .top) {
                            Image(systemName: action.sideEffect == "write" ? "square.and.pencil" : "eye")
                            VStack(alignment: .leading) { Text(action.id).font(.caption.monospaced()); Text(action.description).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(.top, 6)
            }.font(.subheadline)
        }.cardStyle()
    }
}

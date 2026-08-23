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
        }.navigationTitle("Skill 管理").task { await viewModel.load() }
    }
}

struct SkillCard: View {
    let skill: Skill
    let onToggle: @MainActor @Sendable (Bool) -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: skill.icon).font(.title2).frame(width: 32)
            VStack(alignment: .leading) { Text(skill.name).font(.headline); Text(skill.description).foregroundStyle(.secondary) }
            Spacer()
            Toggle("已启用", isOn: Binding(get: { skill.isEnabled }, set: { value in onToggle(value) })).labelsHidden()
        }.cardStyle()
    }
}

import Foundation

@MainActor
final class MemoryViewModel: ObservableObject {
    @Published private(set) var memories: [MemoryItem] = []
    @Published var searchText = ""
    @Published var selectedFilter: MemoryManagerFilter = .all
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let repository: MemoryRepository

    init(repository: MemoryRepository) { self.repository = repository }

    var filteredMemories: [MemoryItem] {
        memories.filter { memory in
            (selectedFilter == .all || (selectedFilter == .deleted && memory.isDeleted) || (selectedFilter == .category(memory.category) && !memory.isDeleted)) &&
            (searchText.isEmpty || memory.content.localizedCaseInsensitiveContains(searchText))
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { memories = try await repository.fetchMemories() }
        catch { errorMessage = error.localizedDescription }
    }

    func save(_ memory: MemoryItem) async {
        do {
            if memories.contains(where: { $0.id == memory.id }) {
                try await repository.updateMemory(memory)
            } else {
                _ = try await repository.createMemory(memory)
            }
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func softDelete(_ memory: MemoryItem) async {
        do { try await repository.softDeleteMemory(memory); await load() }
        catch { errorMessage = error.localizedDescription }
    }

    func permanentlyDelete(_ memory: MemoryItem) async {
        do { try await repository.permanentlyDeleteMemory(memory); await load() }
        catch { errorMessage = error.localizedDescription }
    }
}

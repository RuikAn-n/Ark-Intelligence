import SwiftUI

enum MemoryCategoryStyle {
    static func color(for category: MemoryCategory) -> Color {
        switch category {
        case .project: .blue
        case .preference: .purple
        case .goal: .orange
        case .general: .gray
        }
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardModifier()) }
}

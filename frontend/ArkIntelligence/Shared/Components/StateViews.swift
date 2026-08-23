import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
    }
}

struct ErrorStateView: View {
    let message: String
    var body: some View {
        ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(message))
    }
}

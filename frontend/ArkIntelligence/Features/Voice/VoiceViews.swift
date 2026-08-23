import SwiftUI

@MainActor
final class VoiceViewModel: ObservableObject {
    @Published private(set) var state: VoiceState = .unavailable
    private let service: VoiceService
    init(service: VoiceService) { self.service = service }
    func toggle() async {
        if state == .listening {
            await service.stopListening(); state = .idle
        } else {
            await service.startListening(); state = .listening
        }
    }
}

struct VoiceConversationView: View {
    @ObservedObject var viewModel: VoiceViewModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 72)).foregroundStyle(.secondary)
            Text("语音对话").font(.title.bold())
            Text("语音模型尚未连接").foregroundStyle(.secondary)
            Button(viewModel.state == .listening ? "停止语音对话" : "开始语音对话", systemImage: viewModel.state == .listening ? "stop.fill" : "mic.fill") {
                Task { await viewModel.toggle() }
            }.buttonStyle(.borderedProminent).disabled(viewModel.state == .unavailable)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle("语音对话")
    }
}

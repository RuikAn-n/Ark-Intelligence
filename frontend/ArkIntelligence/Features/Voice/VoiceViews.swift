import SwiftUI

@MainActor
final class VoiceViewModel: ObservableObject {
    let service: LiveVoiceService
    let chat: ChatViewModel
    @Published private(set) var spokenReply = ""
    @Published private(set) var notice = ""
    private var responseEpoch = UUID()

    init(service: LiveVoiceService, chat: ChatViewModel) {
        self.service = service
        self.chat = chat
        service.onSpeechStarted = { [weak self] in self?.responseEpoch = UUID() }
        service.onStop = { [weak self] in self?.responseEpoch = UUID() }
        service.onTranscript = { [weak self] text, farewell in
            guard let self else { return }
            if farewell {
                self.responseEpoch = UUID()
                self.notice = "已返回待唤醒。可点击“结束并整理记忆”保存本次会话。"
                return
            }
            self.submit(text)
        }
    }

    func submit(_ text: String) {
        guard !chat.isEndingSession else { notice = "正在整理记忆，请稍后再说。"; return }
        responseEpoch = UUID()
        let epoch = responseEpoch
        spokenReply = ""
        notice = ""
        service.thinking(true)
        chat.sendVoice(text) { [weak self] event in
            guard let self, self.responseEpoch == epoch, self.service.connected else { return }
            switch event.event {
            case "speech_segment":
                if let text = event.content { self.spokenReply += text + " "; self.service.speak(text) }
            case "approval_required": notice = "请在右侧任务卡片中确认操作。"
            case "error": self.service.interrupt(); self.notice = event.error ?? "本次请求失败"
            case "done": self.service.thinking(false)
            default: break
            }
        }
    }

    func stopSpeaking() { responseEpoch = UUID(); service.interrupt() }
    func stop() { responseEpoch = UUID(); service.stop() }
    func endSession() async {
        stop()
        await chat.endSession()
        notice = chat.sessionError ?? "本次对话已整理到记忆。"
    }
}

struct VoiceConversationView: View {
    @ObservedObject var viewModel: VoiceViewModel
    @ObservedObject private var service: LiveVoiceService
    @ObservedObject private var chat: ChatViewModel

    init(viewModel: VoiceViewModel) {
        self.viewModel = viewModel
        service = viewModel.service
        chat = viewModel.chat
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 20) {
                Spacer(minLength: 12)
                Image(systemName: service.connected ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 88))
                    .foregroundStyle(service.connected ? Color.accentColor : .secondary)
                    .symbolEffect(.pulse, isActive: service.state == .speaking)
                Text("Sophie").font(.largeTitle.bold())
                Text(service.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if service.connected {
                    VStack(spacing: 6) {
                        ProgressView(value: service.inputLevel).tint(service.inputLevel > 0.05 ? .green : .secondary)
                        Text(service.inputFeedback).font(.caption)
                        Text(service.inputDevice).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: 300).accessibilityElement(children: .combine)
                }
                HStack {
                    Picker("输入源", selection: Binding(get: { service.selectedInputID }, set: { id in
                        Task { await service.selectInput(id) }
                    })) {
                        Text("跟随系统").tag("")
                        ForEach(service.inputDevices) { device in Text(device.name).tag(device.id) }
                        if !service.selectedInputID.isEmpty && !service.inputDevices.contains(where: { $0.id == service.selectedInputID }) {
                            Text("所选设备已断开").tag(service.selectedInputID)
                        }
                    }
                    .disabled(service.state == .loading)
                    Button("刷新设备", systemImage: "arrow.clockwise") { service.refreshInputDevices() }.labelStyle(.iconOnly)
                }.frame(maxWidth: 360)
                HStack {
                    if service.connected {
                        Button("直接说话", systemImage: "mic.fill") { service.listen() }
                        Button("测试声音", systemImage: "speaker.wave.2") { service.testSpeaker() }
                        Button("停止朗读", systemImage: "speaker.slash") { viewModel.stopSpeaking() }
                        Button("关闭麦克风", systemImage: "stop.fill") { viewModel.stop() }
                    } else {
                        Button("开启语音", systemImage: "mic.fill") { Task { await service.start() } }
                            .buttonStyle(.borderedProminent).disabled(service.state == .loading)
                        if service.state == .loading { Button("取消") { viewModel.stop() } }
                    }
                }
                if !service.transcript.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("你说").font(.caption).foregroundStyle(.secondary)
                            Text(service.transcript).textSelection(.enabled)
                            if !viewModel.spokenReply.isEmpty {
                                Divider()
                                Text(viewModel.spokenReply).textSelection(.enabled)
                            }
                        }.padding().frame(maxWidth: 580, alignment: .leading)
                    }.frame(maxHeight: 220).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }
                if !viewModel.notice.isEmpty { Text(viewModel.notice).font(.callout).foregroundStyle(.orange) }
                Spacer(minLength: 12)
                Text("中文 · English  /  记忆和 Skill 与文字对话共用")
                    .font(.caption).foregroundStyle(.secondary)
                Button("结束并整理记忆") { Task { await viewModel.endSession() } }
                    .disabled(chat.isBusy || chat.isEndingSession || chat.messages.isEmpty)
                Text("关闭麦克风会停止监听；停止朗读不会撤销已执行的操作。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            TaskPanelView(viewModel: chat).frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
        }.navigationTitle("Sophie 语音对话")
            .onAppear { service.refreshInputDevices() }
    }
}

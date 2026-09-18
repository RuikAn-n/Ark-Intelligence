import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreAudio

// The tap is serialized by AVAudioEngine and never accesses UI state.
private final class ConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if supplied { return false }
        supplied = true
        return true
    }
}

final class MicrophoneEncoder: @unchecked Sendable {
    private let statisticsLock = NSLock()
    private var droppedCount = 0
    var droppedPackets: Int {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        return droppedCount
    }
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    let continuation: AsyncStream<Data>.Continuation
    init(format: AVAudioFormat, continuation: AsyncStream<Data>.Continuation) throws {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else { throw APIError.server("无法转换麦克风音频格式") }
        // VPIO exposes discrete channels. Automatic layout downmix can map
        // all of them to silence; channel 0 is the processed microphone uplink.
        converter.channelMap = [0]
        self.converter = converter; self.continuation = continuation
    }
    // Construct this block outside MainActor. AVAudioEngine invokes it on its
    // realtime service queue; actor-inherited blocks trap before their body runs.
    func makeTap() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in accept(buffer) }
    }
    func accept(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let inputState = ConversionInput()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard inputState.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData; return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { continuation.finish(); return }
        var offset = 0
        while offset < Int(output.frameLength) {
            let count = min(2048, Int(output.frameLength) - offset)
            var pcm = [Int16](repeating: 0, count: count)
            for i in 0..<count { pcm[i] = Int16(max(-1, min(1, channel[offset + i])) * 32767).littleEndian }
            let data = pcm.withUnsafeBytes { Data($0) }
            // bufferingNewest discards stale audio under transient backpressure.
            // Dropping one packet must not permanently close microphone capture.
            switch continuation.yield(data) {
            case .terminated: return
            case .dropped:
                statisticsLock.lock(); droppedCount += 1; statisticsLock.unlock()
            case .enqueued: break
            @unknown default: break
            }
            offset += count
        }
    }
}

@MainActor
final class LiveVoiceService: ObservableObject {
    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var detail = "开启后，说 Hey Sophie 唤醒"
    @Published private(set) var transcript = ""
    @Published private(set) var connected = false
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var inputFeedback = "麦克风未开启"
    @Published private(set) var inputDevice = ""
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedInputID = UserDefaults.standard.string(forKey: "sophie.inputDevice") ?? ""
    func refreshInputDevices() { inputDevices = AudioInputDevice.available() }
    func selectInput(_ id: String) async {
        let wasActive = connected || state == .loading
        if wasActive { stop() }
        selectedInputID = id
        UserDefaults.standard.set(id, forKey: "sophie.inputDevice")
        if wasActive { await start() }
    }
    private var meterTask: Task<Void, Never>?
    private var lastInputAt = Date.distantPast
    private var lastNonzeroInputAt = Date.distantPast
    var onTranscript: ((String, Bool) -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onStop: (() -> Void)?
    private let baseURL: URL
    private let apiClient: APIClient
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var controls: AsyncStream<String>.Continuation?
    private var engine: AVAudioEngine?
    private var captureMixer: AVAudioMixerNode?
    private var audioRestartTask: Task<Void, Never>?
    private var configurationRestarts = 0
    private var player: AVAudioPlayerNode?
    private var microphone: AsyncStream<Data>.Continuation?
    private var validSpeechIDs: Set<String> = []
    private var playbackEpoch = UUID()
    private var connectionEpoch = UUID()
    private var pendingBuffers = 0
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var requestedManual = false
    private var listeningState: VoiceState = .armed
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    init(baseURL: URL, apiURL: URL) { self.baseURL = baseURL; apiClient = APIClient(baseURL: apiURL) }

    func start(manual: Bool = false) async {
        guard state != .loading, !connected else { if manual { listen() }; return }
        configurationRestarts = 0
        requestedManual = manual; state = .loading; detail = "正在连接 Sophie"
        let generation = UUID(); connectionEpoch = generation
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard connectionEpoch == generation else { return }
        guard permission else { fail("请在系统设置的“隐私与安全性 → 麦克风”中允许 Ark Intelligence。"); return }
        do {
            var request = try apiClient.authorizedRequest(.runs)
            var components = URLComponents(url: baseURL.appendingPathComponent("voice"), resolvingAgainstBaseURL: false)!
            components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
            request.url = components.url; request.timeoutInterval = 120
            let socket = URLSession.shared.webSocketTask(with: request); self.socket = socket
            let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(32))
            controls = continuation; socket.resume()
            controlTask = Task { [weak self] in
                do { for await text in stream { try Task.checkCancellation(); try await socket.send(.string(text)) } }
                catch { if self?.connectionEpoch == generation { self?.fail("语音连接已中断：\(error.localizedDescription)") } }
            }
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let packet = try await socket.receive()
                        guard self?.connectionEpoch == generation else { return }
                        if case .string(let text) = packet { try self?.receive(Data(text.utf8)) }
                    }
                } catch { if self?.connectionEpoch == generation { self?.fail("语音服务未连接：\(error.localizedDescription)。请先启动本地语音服务。") } }
            }
        } catch { fail(error.localizedDescription) }
    }

    func stop() {
        onStop?()
        connectionEpoch = UUID()
        controls?.finish(); controls = nil
        receiveTask?.cancel(); audioTask?.cancel(); controlTask?.cancel()
        meterTask?.cancel(); meterTask = nil
        audioRestartTask?.cancel(); audioRestartTask = nil
        receiveTask = nil; audioTask = nil; controlTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        microphone?.finish(); microphone = nil
        stopPlayback()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        configurationObserver = nil; sleepObserver = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; player = nil; captureMixer = nil
        connected = false; state = .idle; detail = "麦克风已关闭"
        inputLevel = 0; lastNonzeroInputAt = .distantPast; inputFeedback = "麦克风已关闭"
    }
    func listen() { guard connected else { return }; interrupt(); command(["command": "listen"]) }
    func arm() { interrupt(); command(["command": "arm"]) }
    func interrupt() { stopPlayback(); command(["command": "interrupt"]) }
    func thinking(_ active: Bool) { command(["command": "thinking", "active": active]) }
    func speak(_ text: String) {
        guard connected, listeningState != .armed, !text.isEmpty else { return }
        let id = UUID().uuidString; validSpeechIDs.insert(id)
        command(["command": "speak", "text": text, "id": id])
    }
    func testSpeaker() {
        guard connected else { return }
        let id = UUID().uuidString
        validSpeechIDs.insert(id)
        command(["command": "speak", "text": "这是一段声音测试。播放期间麦克风会继续监听。你可以检查音量条，确认输入没有中断。", "id": id])
    }
    private func command(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        if case .dropped = controls?.yield(text) { fail("语音队列拥堵，请重新连接。") }
    }
    private func receive(_ data: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = event["event"] as? String else { return }
        switch name {
        case "ready":
            do {
                try startAudio()
                connected = true
                updateState(.armed)
                lastInputAt = .now
                lastNonzeroInputAt = .now
                inputFeedback = "等待麦克风音频…"
                meterTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, self.connected else { return }
                        if Date().timeIntervalSince(self.lastInputAt) > 3 {
                            self.inputLevel = 0
                            self.inputFeedback = "尚未收到音频，请检查麦克风设备"
                        }
                    }
                }
                if requestedManual { listen() }
            } catch {
                fail("语音模型已连接，但麦克风或扬声器初始化失败：\(error.localizedDescription)")
            }
        case "wake": updateState(.listening); chime()
        case "input_level":
            lastInputAt = .now
            let rms = event["rms"] as? Double ?? 0
            inputLevel = max(0, min(1, (20 * log10(max(rms, 0.000001)) + 60) / 60))
            let peak = event["peak"] as? Double ?? 0
            if peak > 0 { lastNonzeroInputAt = .now }
            if Date().timeIntervalSince(lastNonzeroInputAt) > 3 {
                inputFeedback = "麦克风持续返回静音，请检查输入设备或静音开关"
            } else {
                inputFeedback = rms > 0.003 ? "已收到声音" : "正在监听，当前声音较小"
            }
        case "speech_started": stopPlayback(); onSpeechStarted?(); updateState(.listening)
        case "interrupted": break // Already invalidated locally; an old acknowledgement must not clear new IDs.
        case "status":
            if let value = event["state"] as? String, let state = VoiceState(rawValue: value) { updateState(state) }
            if let message = event["message"] as? String { detail = message }
        case "transcript":
            let text = event["text"] as? String ?? ""; transcript = text
            onTranscript?(text, event["farewell"] as? Bool ?? false)
        case "audio":
            guard let id = event["id"] as? String, validSpeechIDs.contains(id), let pcm = event["pcm"] as? String,
                  let bytes = Data(base64Encoded: pcm), event["sample_rate"] as? Int == 24_000 else { return }
            play(bytes)
        case "speech_done": if let id = event["id"] as? String { validSpeechIDs.remove(id) }
        case "error": fail(event["message"] as? String ?? "语音处理失败")
        default: break
        }
    }
    private func startAudio(reusing existing: AVAudioEngine? = nil) throws {
        let audioEngine = existing ?? AVAudioEngine()
        refreshInputDevices()
        let selected = inputDevices.first { $0.id == selectedInputID }
        if !selectedInputID.isEmpty, selected == nil { throw APIError.server("所选麦克风已断开，请选择其他输入源") }
        inputDevice = selected?.name ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "系统默认麦克风"
        if existing == nil {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
            audioEngine.inputNode.isVoiceProcessingInputMuted = false
            try selected?.select(on: audioEngine.inputNode)
        }
        let playback = AVAudioPlayerNode(); audioEngine.attach(playback)
        audioEngine.connect(playback, to: audioEngine.mainMixerNode, format: playbackFormat)
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError.server("没有可用的麦克风") }
        // VoiceProcessingIO requires matching client-side input/output formats.
        // The player is 24 kHz, but the I/O graph must use the microphone format;
        // the mixer performs playback conversion rather than reformatting VPIO.
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: format)
        // Keep microphone capture in the rendered graph through a muted branch.
        let captureMixer = AVAudioMixerNode()
        audioEngine.attach(captureMixer)
        audioEngine.connect(audioEngine.inputNode, to: captureMixer, format: format)
        audioEngine.connect(captureMixer, to: audioEngine.mainMixerNode, format: format)
        captureMixer.outputVolume = 0 // Never monitor microphone audio through speakers.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let encoder = try MicrophoneEncoder(format: format, continuation: continuation)
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: encoder.makeTap())
        engine = audioEngine; player = playback; self.captureMixer = captureMixer; microphone = continuation
        audioEngine.prepare(); try audioEngine.start()
        let generation = connectionEpoch; let connection = socket
        audioTask = Task.detached { [weak self] in
            do {
                var reportedDrops = -1
                for await data in stream {
                    try Task.checkCancellation()
                    try await connection?.send(.data(data))
                    let dropped = encoder.droppedPackets
                    if dropped != reportedDrops {
                        try await connection?.send(.string("{\"command\":\"capture_status\",\"dropped_packets\":\(dropped)}"))
                        reportedDrops = dropped
                    }
                }
                if !Task.isCancelled {
                    await self?.audioFailed("麦克风音频格式转换失败，请重新选择输入源。", generation: generation)
                }
            } catch {
                if !Task.isCancelled { await self?.audioFailed(error.localizedDescription, generation: generation) }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverAudioConfiguration() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }
    private func audioFailed(_ message: String, generation: UUID) {
        guard connectionEpoch == generation else { return }
        fail(message)
    }
    private func recoverAudioConfiguration() {
        guard connected else { return }
        audioRestartTask?.cancel()
        audioRestartTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.connected, let engine = self.engine else { return }
            self.configurationRestarts += 1
            guard self.configurationRestarts <= 3 else {
                self.fail("音频设备反复切换，请选择稳定的输入源后重新开启语音。")
                return
            }
            self.interrupt()
            if let observer = self.configurationObserver { NotificationCenter.default.removeObserver(observer) }
            if let observer = self.sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            self.configurationObserver = nil; self.sleepObserver = nil
            self.audioTask?.cancel(); self.microphone?.finish()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.disconnectNodeOutput(engine.inputNode)
            if let player = self.player { engine.detach(player) }
            if let mixer = self.captureMixer { engine.detach(mixer) }
            do {
                try self.startAudio(reusing: engine)
                self.lastInputAt = .now
                self.inputFeedback = "输入设备已更新，等待音频…"
            } catch { self.fail("重新连接麦克风失败：\(error.localizedDescription)") }
        }
    }
    private func updateState(_ value: VoiceState) {
        if value == .armed || value == .listening { listeningState = value }
        if pendingBuffers == 0 { state = value }
        detail = switch value {
        case .idle: "麦克风已关闭"
        case .loading: "正在加载本地模型"
        case .armed: "说 Hey Sophie 唤醒"
        case .listening: "我在听，停顿后自动发送"
        case .processing: "正在识别"
        case .speaking: "Sophie 正在说话，说 Hey Sophie 或点击直接说话可插话"
        case .unavailable: "语音暂不可用"
        }
    }
    private func play(_ bytes: Data) {
        guard bytes.count % 2 == 0, bytes.count > 0, bytes.count <= 1_000_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(bytes.count / 2)),
              let output = buffer.floatChannelData?[0], let player else { return }
        guard pendingBuffers < 128 else { fail("播放速度落后于生成速度，请重新连接。"); return }
        buffer.frameLength = buffer.frameCapacity
        bytes.withUnsafeBytes { raw in
            for i in 0..<Int(buffer.frameLength) { output[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        schedule(buffer, player: player)
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, player: AVAudioPlayerNode) {
        let generation = playbackEpoch
        if pendingBuffers == 0 { command(["command": "playback", "active": true]) }
        pendingBuffers += 1; state = .speaking
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackEpoch == generation else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 { self.command(["command": "playback", "active": false]); self.updateState(self.listeningState) }
            }
        }
        if !player.isPlaying { player.play() }
    }
    private func chime() {
        guard let player, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 2880), let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 2880
        for i in 0..<2880 {
            let t = Double(i) / 24_000; let envelope = sin(Double.pi * Double(i) / 2880)
            samples[i] = Float(0.12 * envelope * sin(2 * Double.pi * 880 * t))
        }
        schedule(buffer, player: player)
    }
    private func stopPlayback() {
        playbackEpoch = UUID(); validSpeechIDs.removeAll(); pendingBuffers = 0; player?.stop()
        command(["command": "playback", "active": false])
    }
    private func fail(_ message: String) { stop(); state = .unavailable; detail = message }
}

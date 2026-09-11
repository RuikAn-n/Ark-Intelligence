import XCTest
@preconcurrency import AVFoundation
@testable import ArkIntelligence

@MainActor
private final class VoiceChatRepository: ChatRepository {
    var voiceRequests = 0
    func streamMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamVoiceMessage(_ message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        voiceRequests += 1
        return AsyncThrowingStream {
            $0.yield(ChatStreamEvent(event: "token", content: "Hello. "))
            $0.yield(ChatStreamEvent(event: "speech_segment", content: "Hello."))
            $0.yield(ChatStreamEvent(event: "token", content: "I'm Sophie."))
            $0.yield(ChatStreamEvent(event: "speech_segment", content: "I'm Sophie."))
            $0.yield(ChatStreamEvent(event: "answer", content: "Hello. I'm Sophie."))
            $0.yield(ChatStreamEvent(event: "done"))
            $0.finish()
        }
    }
    func endSession() async throws -> SessionEndResponse { SessionEndResponse(status: "ok") }
    func submitApproval(runID: String, callID: String, digest: String, approved: Bool) async throws {}
    func cancel(runID: String) async throws {}
    func restoreHistory(_ messages: [ChatMessage]) {}
}

final class VoiceTests: XCTestCase {
    @MainActor
    func testMicrophoneTapRunsOnAudioThreadAndResamples() async throws {
        try await checkSignal(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!)
    }
    @MainActor
    func testDiscreteVoiceProcessingChannelsPreserveMicrophoneSignal() async throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        try await checkSignal(AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout))
    }
    @MainActor
    private func checkSignal(_ format: AVAudioFormat) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let encoder = try MicrophoneEncoder(format: format, continuation: continuation)
        // The encoder is created on MainActor, exactly as in the live app.
        await Task.detached {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for i in 0..<4800 {
                for channel in 0..<Int(format.channelCount) { buffer.floatChannelData![channel][i] = 0.25 * sin(2 * .pi * 440 * Float(i) / 48_000) }
            }
            encoder.makeTap()(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            continuation.finish()
        }.value
        var bytes = 0
        var peak = 0
        for await packet in stream {
            XCTAssertLessThanOrEqual(packet.count, 4096)
            XCTAssertEqual(packet.count % 2, 0)
            bytes += packet.count
            packet.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: packet.count, by: 2) {
                    peak = max(peak, abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))))
                }
            }
        }
        XCTAssertGreaterThan(peak, 7000, "A nonzero microphone signal must survive conversion")
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThanOrEqual(bytes, 3200)
    }
    @MainActor
    func testTemporaryBackpressureDoesNotEndMicrophoneStream() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let encoder = try MicrophoneEncoder(format: format, continuation: continuation)
        await Task.detached {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            // Simulate a sender stalled during TTS while recording keeps running.
            for value: Float in [0.1, 0.2, 0.3, 0.4] {
                buffer.floatChannelData![0].initialize(repeating: value, count: 1600)
                encoder.accept(buffer)
            }
            continuation.finish()
        }.value
        var packets: [Data] = []
        for await packet in stream { packets.append(packet) }
        XCTAssertGreaterThan(encoder.droppedPackets, 0)
        XCTAssertEqual(packets.count, 1)
        let last = try XCTUnwrap(packets.last)
        let sample = last.withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) }
        XCTAssertGreaterThan(sample, 12000, "Capture must continue with fresh audio after overflow")
    }

    @MainActor
    func testVoiceSharesChatHistoryAndDoesNotDuplicateFinalAnswer() async throws {
        let repository = VoiceChatRepository()
        let chat = ChatViewModel(repository: repository, memoryRepository: MockMemoryRepository())
        var segments: [String] = []
        chat.sendVoice("Hello") { event in
            if event.event == "speech_segment", let text = event.content { segments.append(text) }
        }
        for _ in 0..<100 where chat.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(repository.voiceRequests, 1)
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.content), ["Hello"])
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.map(\.content), ["Hello. I'm Sophie."])
        XCTAssertEqual(segments, ["Hello.", "I'm Sophie."])
        XCTAssertFalse(chat.isBusy)
    }
}

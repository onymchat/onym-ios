import XCTest
@testable import OnymIOS

/// Wire-format + waveform coverage for voice messages
/// (`ChatVoiceAttachment` on `ChatMessagePayload`, `ChatVoiceEncoder`).
final class ChatVoiceAttachmentTests: XCTestCase {

    private func sampleVoice() -> ChatVoiceAttachment {
        ChatVoiceAttachment(
            sha256: String(repeating: "ab", count: 32),
            mimeType: "audio/mp4",
            byteSize: 48_000,
            durationSeconds: 7.5,
            encKey: Data(repeating: 0x33, count: 32),
            waveform: (0..<40).map { UInt8($0 * 6 % 256) },
            server: "https://blossom.onym.app"
        )
    }

    func test_payload_withVoice_roundTrips() throws {
        let payload = ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: Data(repeating: 0x22, count: 32),
            senderBlsPubkeyHex: String(repeating: "cd", count: 48),
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: nil,
            variant: .tyranny(body: ""),
            voiceAttachment: sampleVoice()
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: data)

        let voice = try XCTUnwrap(decoded.voiceAttachment)
        XCTAssertEqual(voice, sampleVoice())
        XCTAssertEqual(voice.durationSeconds, 7.5)
        XCTAssertEqual(voice.waveform.count, 40)
        XCTAssertNil(decoded.attachment)
        XCTAssertNil(decoded.videoAttachment)
        XCTAssertNil(decoded.attachments)

        // Snake_case wire keys.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"voice_attachment\""))
        XCTAssertTrue(json.contains("\"duration_seconds\""))
        XCTAssertTrue(json.contains("\"waveform\""))
    }

    func test_payload_withoutVoice_decodesToNil() throws {
        let payload = ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: Data(repeating: 0x01, count: 32),
            senderBlsPubkeyHex: String(repeating: "ab", count: 48),
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: nil,
            variant: .tyranny(body: "hi")
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: data)
        XCTAssertNil(decoded.voiceAttachment)
    }

    // MARK: - Waveform downsampling

    func test_downsample_emptySamples_returnsZeroedBars() {
        let bars = ChatVoiceEncoder.downsample([], barCount: 40)
        XCTAssertEqual(bars.count, 40)
        XCTAssertTrue(bars.allSatisfy { $0 == 0 })
    }

    func test_downsample_alwaysReturnsRequestedBarCount() {
        // Fewer samples than bars still pads to the requested width.
        let short = ChatVoiceEncoder.downsample([100, -100, 100], barCount: 40)
        XCTAssertEqual(short.count, 40)

        let long = ChatVoiceEncoder.downsample(
            (0..<10_000).map { Int16(truncatingIfNeeded: $0) }, barCount: 40
        )
        XCTAssertEqual(long.count, 40)
    }

    func test_downsample_normalizesToLoudestBucket() {
        // A ramp of increasing amplitude: the loudest bucket hits the top
        // of the 0…255 range, and the bars are non-decreasing.
        let samples = (0..<4_000).map { Int16(truncatingIfNeeded: $0 * 8) }
        let bars = ChatVoiceEncoder.downsample(samples, barCount: 40)
        XCTAssertEqual(bars.count, 40)
        XCTAssertEqual(bars.max(), 255)
        for i in 1..<bars.count {
            XCTAssertGreaterThanOrEqual(bars[i], bars[i - 1])
        }
    }

    func test_format_rendersMinutesSeconds() {
        XCTAssertEqual(ChatVoiceMessageView.format(0), "0:00")
        XCTAssertEqual(ChatVoiceMessageView.format(9.4), "0:09")
        XCTAssertEqual(ChatVoiceMessageView.format(67), "1:07")
    }
}

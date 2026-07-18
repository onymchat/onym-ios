import Foundation
import AVFoundation

/// Live microphone capture for voice messages. Records mono AAC into a
/// temp `.m4a`, exposes a live input level for a record-time animation, and
/// hands back the file URL + duration on stop. `ChatVoiceEncoder` turns the
/// resulting file into the wire descriptor (bytes + duration + waveform).
///
/// Owned by `ChatInputPanelView`: holding the mic button starts recording,
/// releasing stops + sends, and sliding to cancel aborts + deletes.
final class ChatVoiceRecorder: NSObject {
    enum RecordError: Error {
        /// The user denied (or has previously denied) microphone access.
        case permissionDenied
        /// The audio session couldn't be configured / activated.
        case sessionFailed
        /// `AVAudioRecorder` couldn't be created or wouldn't start.
        case recorderFailed
    }

    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    /// A clip shorter than this (seconds) on release is treated as an
    /// accidental tap and discarded rather than sent.
    static let minimumDuration: TimeInterval = 0.5

    /// Request permission + begin recording to a fresh temp file. Throws
    /// `permissionDenied` if the mic is off-limits, or `sessionFailed` /
    /// `recorderFailed` if capture can't start.
    func start() async throws {
        guard await Self.requestPermission() else { throw RecordError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw RecordError.sessionFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        // Mono AAC at a modest sample rate + bitrate keeps a minute of
        // speech well under a few hundred KB.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32_000,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            throw RecordError.recorderFailed
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecordError.recorderFailed }
        self.recorder = recorder
        self.currentURL = url
    }

    /// Whether a recording is currently in progress.
    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Elapsed recording time in seconds.
    var duration: TimeInterval { recorder?.currentTime ?? 0 }

    /// Current normalized input level (0…1) for a record-time pulse.
    func currentLevel() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let clamped = max(-60, min(0, db))
        return (clamped + 60) / 60
    }

    /// Stop recording and return the file URL + duration, or `nil` if there
    /// was nothing recording. The caller decides whether the clip is long
    /// enough to send (see `minimumDuration`).
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = currentURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (url, duration)
    }

    /// Abort + delete the in-progress recording (slide-to-cancel or a
    /// too-short clip).
    func cancel() {
        recorder?.stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

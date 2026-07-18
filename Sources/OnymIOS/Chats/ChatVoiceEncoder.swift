import Foundation
import AVFoundation

/// Turns a recorded `.m4a` voice clip into wire form: the raw AAC bytes,
/// the playback duration, and a small downsampled amplitude waveform the
/// bubble renders without ever fetching the audio.
///
/// Injected into `SendMessageInteractor` (like `ChatVideoEncoder`) so the
/// UI-test harness can substitute a canned encoding instead of reading a
/// real file off disk.
enum ChatVoiceEncoder {
    struct Encoded: Equatable {
        /// Raw AAC-in-MPEG-4 (`.m4a`) bytes — encrypted + uploaded as-is.
        let m4a: Data
        /// Playback duration in seconds.
        let durationSeconds: Double
        /// Downsampled amplitude bars (0…255), `waveformBarCount` of them.
        let waveform: [UInt8]
    }

    /// Number of bars the waveform is downsampled to. Small + fixed so the
    /// descriptor stays tiny on the wire and the bubble layout is stable.
    static let waveformBarCount = 40

    /// Read `url` into `Encoded`. Returns `nil` if the file can't be read
    /// or has no duration. A missing waveform (e.g. an unreadable audio
    /// track) degrades to an empty array — the bubble still plays.
    static func encode(fromAudioURL url: URL) async -> Encoded? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let cmDuration = try? await asset.load(.duration) else { return nil }
        let duration = CMTimeGetSeconds(cmDuration)
        let waveform = (try? await computeWaveform(asset: asset, barCount: waveformBarCount)) ?? []
        return Encoded(
            m4a: data,
            durationSeconds: duration.isFinite ? max(0, duration) : 0,
            waveform: waveform
        )
    }

    /// Decode the audio track to PCM, bucket the samples into `barCount`
    /// groups, and emit each bucket's RMS normalized to 0…255. Pure enough
    /// to unit-test via the `downsample` helper below.
    static func computeWaveform(asset: AVURLAsset, barCount: Int) async throws -> [UInt8] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var chunk = Data(count: length)
            let copied = chunk.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: base
                ) == kCMBlockBufferNoErr
            }
            guard copied else { continue }
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let ptr = raw.bindMemory(to: Int16.self)
                samples.append(contentsOf: ptr)
            }
        }
        return downsample(samples, barCount: barCount)
    }

    /// Bucket `samples` into `barCount` RMS values normalized to the loudest
    /// bucket (0…255). Pure — the unit test pins the shape without AVFoundation.
    static func downsample(_ samples: [Int16], barCount: Int) -> [UInt8] {
        guard barCount > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 0, count: barCount) }
        let bucketSize = max(1, samples.count / barCount)
        var rmsValues: [Double] = []
        var maxRms: Double = 0
        var idx = 0
        while idx < samples.count && rmsValues.count < barCount {
            let end = min(idx + bucketSize, samples.count)
            var sum = 0.0
            for i in idx..<end {
                let v = Double(samples[i]) / Double(Int16.max)
                sum += v * v
            }
            let rms = end > idx ? (sum / Double(end - idx)).squareRoot() : 0
            rmsValues.append(rms)
            maxRms = max(maxRms, rms)
            idx = end
        }
        var bars = rmsValues.map { rms -> UInt8 in
            let norm = maxRms > 0 ? rms / maxRms : 0
            return UInt8(max(0, min(255, (norm * 255).rounded())))
        }
        // Very short clips may produce fewer buckets than requested — pad
        // so the bubble layout is always `barCount` wide.
        while bars.count < barCount { bars.append(0) }
        return bars
    }
}

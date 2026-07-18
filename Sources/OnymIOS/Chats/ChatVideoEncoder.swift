import AVFoundation
import UIKit

/// Transcodes a picked video to a 720p-class MP4 for transmission and
/// extracts a poster frame. Sibling to `ChatImageEncoder`: what we
/// encrypt + upload to Blossom is a sensibly-sized H.264 clip, and the
/// message carries a poster (itself an encoded image) so the bubble has
/// something to render before playback.
///
/// The transcode bounds both the pixel dimensions (≤720p) and, in
/// practice, the byte size — most phone clips land well under the
/// Blossom upload cap after re-encoding. The interactor still guards the
/// final ciphertext size for the pathological long-clip case.
enum ChatVideoEncoder {
    /// 720p-class export preset (longest edge ≤ 1280).
    static let exportPreset = AVAssetExportPreset1280x720

    struct Encoded: Equatable {
        /// Transcoded MP4 bytes (plaintext, pre-encryption).
        let mp4: Data
        /// Transcoded display dimensions (rotation-corrected).
        let width: Int
        let height: Int
        /// Playback duration in seconds.
        let durationSeconds: Double
        /// The first frame, run through `ChatImageEncoder` so it ships
        /// with a JPEG + blurhash + dimensions like any sent photo.
        let poster: ChatImageEncoder.Encoded
    }

    /// Transcode + extract poster. Returns `nil` on any decode /
    /// export / poster-extraction failure (the caller maps that to a
    /// user-facing "couldn't process the video").
    static func encode(fromVideoURL url: URL) async -> Encoded? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: exportPreset) else {
            return nil
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard let mp4 = try? Data(contentsOf: outputURL) else { return nil }
        let outAsset = AVURLAsset(url: outputURL)

        let duration: Double
        if let cmDuration = try? await outAsset.load(.duration) {
            duration = max(0, CMTimeGetSeconds(cmDuration))
        } else {
            duration = 0
        }

        // Display dimensions, rotation-corrected via the track transform.
        var width = 0
        var height = 0
        if let track = try? await outAsset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let displaySize = naturalSize.applying(transform)
            width = Int(abs(displaySize.width))
            height = Int(abs(displaySize.height))
        }

        // Poster: first frame → the image encoder (JPEG + blurhash + dims).
        let generator = AVAssetImageGenerator(asset: outAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: ChatImageEncoder.maxEdge, height: ChatImageEncoder.maxEdge
        )
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        guard let poster = ChatImageEncoder.encode(UIImage(cgImage: cgImage)) else { return nil }

        // Fall back to the poster's dimensions if the track query failed.
        if width == 0 || height == 0 {
            width = poster.width
            height = poster.height
        }

        return Encoded(
            mp4: mp4,
            width: width,
            height: height,
            durationSeconds: duration,
            poster: poster
        )
    }
}

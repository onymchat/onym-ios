import AVFoundation
import UIKit

/// Inline voice-message player rendered inside a chat bubble: a
/// play/pause button, a static waveform (from the descriptor), and an
/// `m:ss` duration. Tapping play lazily downloads + decrypts the audio
/// via `ChatVoiceLoader` and plays it with an `AVAudioPlayer`, animating
/// the waveform progress as it goes.
///
/// Send-state aware: an outgoing `.pending` clip shows a spinner in place
/// of the play button; an outgoing `.failed` clip shows an error glyph and
/// routes taps to the host's Resend/Delete menu instead of playback.
final class ChatVoiceMessageView: UIView {
    /// Fixed content height so the bubble's frame is stable from first layout.
    static let contentHeight: CGFloat = 40

    private let playButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let waveform = VoiceWaveformView()
    private let durationLabel = UILabel()

    private var loader: ChatVoiceLoader?
    private var attachment: ChatVoiceAttachment?
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var displayLink: CADisplayLink?
    private var onFailedTap: (() -> Void)?
    private var isLoading = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chat.bubble.voice"

        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        playButton.configuration = config
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.accessibilityIdentifier = "chat.bubble.voice.play"
        playButton.addTarget(self, action: #selector(tappedPlay), for: .touchUpInside)
        addSubview(playButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        waveform.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waveform)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(durationLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.contentHeight),

            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 32),
            playButton.heightAnchor.constraint(equalToConstant: 32),

            spinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            waveform.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 8),
            waveform.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 24),
            waveform.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),

            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Configure

    func configure(
        voice: ChatVoiceAttachment,
        loader: ChatVoiceLoader?,
        tint: UIColor,
        trackColor: UIColor,
        status: MessageStatus,
        direction: MessageDirection,
        onFailedTap: (() -> Void)?
    ) {
        // A different clip in a recycled cell — stop any prior playback.
        if attachment?.sha256 != voice.sha256 { reset() }
        self.attachment = voice
        self.loader = loader
        self.onFailedTap = onFailedTap

        playButton.tintColor = tint
        spinner.color = tint
        durationLabel.textColor = tint
        durationLabel.text = Self.format(voice.durationSeconds)
        waveform.playedColor = tint
        waveform.trackColor = trackColor
        waveform.samples = voice.waveform
        waveform.progress = 0

        let isPending = direction == .outgoing && status == .pending
        let isFailed = direction == .outgoing && status == .failed
        if isPending {
            playButton.isHidden = true
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
            playButton.isHidden = false
            let symbol = isFailed ? "exclamationmark.circle.fill" : "play.circle.fill"
            playButton.setImage(
                UIImage(systemName: symbol, withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)),
                for: .normal
            )
            if isFailed { playButton.tintColor = UIColor(OnymTokens.red) }
        }
    }

    /// Stop playback + tear down the player. Called on reuse / new clip.
    func reset() {
        player?.stop()
        player = nil
        playerDelegate = nil
        displayLink?.invalidate()
        displayLink = nil
        isLoading = false
        waveform.progress = 0
        setPlayGlyph(playing: false)
    }

    // MARK: - Playback

    @objc private func tappedPlay() {
        // Failed clips route to the host's Resend/Delete menu.
        if let onFailedTap {
            onFailedTap()
            return
        }
        if let player {
            if player.isPlaying {
                player.pause()
                stopDisplayLink()
                setPlayGlyph(playing: false)
            } else {
                activatePlaybackSession()
                player.play()
                startDisplayLink()
                setPlayGlyph(playing: true)
            }
            return
        }
        guard !isLoading, let attachment, let loader else { return }
        isLoading = true
        playButton.isHidden = true
        spinner.startAnimating()
        Task { [weak self] in
            let url = try? await loader.fileURL(for: attachment)
            await MainActor.run {
                guard let self else { return }
                self.isLoading = false
                self.spinner.stopAnimating()
                self.playButton.isHidden = false
                // The cell may have been reused for a different clip while
                // the blob downloaded.
                guard let url, self.attachment?.sha256 == attachment.sha256 else { return }
                self.startPlayback(from: url)
            }
        }
    }

    private func startPlayback(from url: URL) {
        activatePlaybackSession()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        let delegate = PlayerDelegate { [weak self] in self?.playbackFinished() }
        player.delegate = delegate
        self.playerDelegate = delegate
        self.player = player
        player.play()
        startDisplayLink()
        setPlayGlyph(playing: true)
    }

    private func playbackFinished() {
        stopDisplayLink()
        waveform.progress = 0
        player?.currentTime = 0
        setPlayGlyph(playing: false)
    }

    private func setPlayGlyph(playing: Bool) {
        let symbol = playing ? "pause.circle.fill" : "play.circle.fill"
        playButton.setImage(
            UIImage(systemName: symbol, withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)),
            for: .normal
        )
    }

    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tickProgress))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tickProgress() {
        guard let player, player.duration > 0 else { return }
        waveform.progress = CGFloat(player.currentTime / player.duration)
    }

    // MARK: - Helpers

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Retains a closure-backed `AVAudioPlayerDelegate` (the player only
    /// weakly references its delegate).
    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish()
        }
    }
}

/// Draws a voice-message waveform as vertical rounded bars from a
/// normalized `[UInt8]` sample array, coloring bars up to `progress` in
/// `playedColor` and the rest in `trackColor`.
final class VoiceWaveformView: UIView {
    var samples: [UInt8] = [] { didSet { setNeedsDisplay() } }
    var progress: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var playedColor: UIColor = .label { didSet { setNeedsDisplay() } }
    var trackColor: UIColor = .tertiaryLabel { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ rect: CGRect) {
        guard !samples.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        let count = samples.count
        let spacing: CGFloat = 2
        let barWidth = max(1.5, (rect.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let midY = rect.height / 2
        let playedUpTo = progress * CGFloat(count)
        for (i, sample) in samples.enumerated() {
            let norm = CGFloat(sample) / 255
            let barHeight = max(3, norm * rect.height)
            let x = CGFloat(i) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            let color = CGFloat(i) < playedUpTo ? playedColor : trackColor
            ctx.setFillColor(color.cgColor)
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }
    }
}

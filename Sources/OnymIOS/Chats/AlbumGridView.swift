import UIKit

/// Renders a multi-media album inside a chat bubble as a compact grid of
/// up to four tiles (a "+N" overlay on the fourth when there are more).
/// Each tile shows the item's poster (blurhash placeholder → decrypted
/// poster via `ChatImageLoader`), a small play glyph for videos, and
/// forwards taps as an index into the album so the host can open the
/// full-screen gallery at the right item.
///
/// Rebuilt on every `configure` (cells are reused); per-tile SHA guards
/// keep the async poster loads from landing on a recycled tile.
final class AlbumGridView: UIView {
    private var tiles: [Tile] = []
    private var onTapIndex: ((Int) -> Void)?
    /// Number of columns; 2 for everything except a 2-item album (side by
    /// side reads better than stacked).
    private let spacing: CGFloat = 2

    private let rowStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        rowStack.axis = .vertical
        rowStack.distribution = .fillEqually
        rowStack.spacing = spacing
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.clipsToBounds = true
        rowStack.layer.cornerRadius = 10
        rowStack.layer.cornerCurve = .continuous
        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Number of grid rows for a given item count (2 columns, ≤4 shown).
    static func rowCount(for itemCount: Int) -> Int {
        min(itemCount, 4) <= 2 ? 1 : 2
    }

    func configure(
        items: [ChatMediaAttachment],
        imageLoader: ChatImageLoader?,
        onTapIndex: @escaping (Int) -> Void
    ) {
        self.onTapIndex = onTapIndex
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []

        let shown = min(items.count, 4)
        let columns = 2
        var index = 0
        var currentRow: UIStackView?
        for i in 0..<shown {
            if i % columns == 0 {
                let row = UIStackView()
                row.axis = .horizontal
                row.distribution = .fillEqually
                row.spacing = spacing
                rowStack.addArrangedSubview(row)
                currentRow = row
            }
            let tile = Tile()
            let tapIndex = i
            tile.onTap = { [weak self] in self?.onTapIndex?(tapIndex) }
            // "+N more" overlay on the last shown tile when there's overflow.
            let overflow = (i == shown - 1 && items.count > shown) ? items.count - shown : 0
            tile.apply(item: items[i], imageLoader: imageLoader, overflowCount: overflow)
            currentRow?.addArrangedSubview(tile)
            tiles.append(tile)
            index += 1
        }
        // A trailing odd tile (e.g. 3 items) leaves the last row's second
        // slot empty; fill it so `fillEqually` keeps the grid square.
        if shown % columns != 0, let row = currentRow {
            let spacer = UIView()
            spacer.backgroundColor = .clear
            row.addArrangedSubview(spacer)
        }
    }

    // MARK: - Tile

    private final class Tile: UIView {
        var onTap: (() -> Void)?
        private let imageView = UIImageView()
        private let playGlyph = UIImageView()
        private let overflowLabel = UILabel()
        private var currentSha: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            backgroundColor = UIColor(OnymTokens.surface3)

            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = true
            addSubview(imageView)

            playGlyph.translatesAutoresizingMaskIntoConstraints = false
            playGlyph.image = UIImage(
                systemName: "play.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            )
            playGlyph.tintColor = .white
            playGlyph.isHidden = true
            addSubview(playGlyph)

            overflowLabel.translatesAutoresizingMaskIntoConstraints = false
            overflowLabel.font = .systemFont(ofSize: 22, weight: .semibold)
            overflowLabel.textColor = .white
            overflowLabel.textAlignment = .center
            overflowLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            overflowLabel.isHidden = true
            addSubview(overflowLabel)

            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
                playGlyph.centerXAnchor.constraint(equalTo: centerXAnchor),
                playGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                overflowLabel.topAnchor.constraint(equalTo: topAnchor),
                overflowLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                overflowLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                overflowLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            accessibilityIdentifier = "chat.bubble.album.tile"
            isAccessibilityElement = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func tapped() { onTap?() }

        func apply(item: ChatMediaAttachment, imageLoader: ChatImageLoader?, overflowCount: Int) {
            let poster = item.thumbnail
            currentSha = poster.sha256
            playGlyph.isHidden = !item.isVideo
            overflowLabel.isHidden = overflowCount <= 0
            overflowLabel.text = overflowCount > 0 ? "+\(overflowCount)" : nil
            imageView.image = Blurhash.decode(poster.blurhash, size: CGSize(width: 24, height: 24))
            guard let imageLoader else { return }
            let sha = poster.sha256
            Task { [weak self] in
                let image = try? await imageLoader.image(for: poster)
                await MainActor.run {
                    guard let self, self.currentSha == sha, let image else { return }
                    self.imageView.image = image
                }
            }
        }
    }
}

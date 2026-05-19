import SwiftUI
import UIKit

/// Top-level chat-screen controller. UIKit-first per the design call
/// (#150 plan): nav bar, message list, and input panel are all
/// UIKit. SwiftUI hosts this controller via `ChatThreadView`.
///
/// PR 5 scope — skeleton only:
/// - Custom title bar at the top (back chevron, group name, info
///   button). SwiftUI's nav bar is hidden by the wrapper.
/// - Empty `UITableView` placeholder where messages will render in
///   PR 6.
/// - Empty `UIView` placeholder where the input panel + send button
///   will land in PR 6 / PR 7.
///
/// No keyboard handling, no message rendering, no send — those
/// arrive in later PRs. Tapping the info button forwards to the
/// SwiftUI parent, which pushes `ChatMembersView` via
/// `navigationDestination(isPresented:)`.
final class ChatThreadViewController: UIViewController {
    /// Invoked when the user taps the back chevron. The SwiftUI
    /// wrapper points this at `Environment(\.dismiss)` so the
    /// existing `NavigationStack` pops correctly.
    var onBack: (() -> Void)?

    /// Invoked when the user taps the info button. The SwiftUI
    /// wrapper toggles a `@State` flag that triggers the members-
    /// view push.
    var onShowMembers: (() -> Void)?

    private let titleLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let infoButton = UIButton(type: .system)
    private let topBar = UIView()
    private let topBarSeparator = UIView()
    private let tableView = UITableView()
    private let inputPanel = UIView()
    private let inputPanelSeparator = UIView()
    private let inputPlaceholderLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(OnymTokens.bg)
        buildTopBar()
        buildTableView()
        buildInputPanel()
        layout()
    }

    /// Push a new group-name into the title. Called by the SwiftUI
    /// wrapper on every render — keeps the bar in sync as the group
    /// renames (PR 9 polish) without re-creating the controller.
    func update(groupName: String) {
        titleLabel.text = groupName.isEmpty ? "Chat" : groupName
    }

    // MARK: - Top bar

    private func buildTopBar() {
        topBar.backgroundColor = UIColor(OnymTokens.bg)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        // Back chevron. SF Symbol chevron.left at semantic accent so
        // it reads as a tap target in both light and dark.
        var backConfig = UIButton.Configuration.plain()
        backConfig.image = UIImage(systemName: "chevron.left",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        backConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        backButton.configuration = backConfig
        backButton.tintColor = UIColor(OnymTokens.text2)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.addTarget(self, action: #selector(tappedBack), for: .touchUpInside)
        backButton.accessibilityLabel = "Back"
        backButton.accessibilityIdentifier = "chat.back"
        topBar.addSubview(backButton)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = UIColor(OnymTokens.text)
        titleLabel.textAlignment = .center
        titleLabel.text = "Chat"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.accessibilityIdentifier = "chat.title"
        topBar.addSubview(titleLabel)

        var infoConfig = UIButton.Configuration.plain()
        infoConfig.image = UIImage(systemName: "info.circle",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        infoConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        infoButton.configuration = infoConfig
        infoButton.tintColor = UIColor(OnymTokens.text2)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.addTarget(self, action: #selector(tappedInfo), for: .touchUpInside)
        infoButton.accessibilityLabel = "Group info"
        infoButton.accessibilityIdentifier = "chat.info"
        topBar.addSubview(infoButton)

        topBarSeparator.backgroundColor = UIColor(OnymTokens.hairline)
        topBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarSeparator)
    }

    // MARK: - Table view (messages placeholder)

    private func buildTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = UIColor(OnymTokens.bg)
        tableView.separatorStyle = .none
        // No data source yet — PR 6 attaches a diffable data source
        // and a custom bubble cell. Empty table renders as a blank
        // background, which is the desired PR-5 visual.
        view.addSubview(tableView)
    }

    // MARK: - Input panel placeholder

    private func buildInputPanel() {
        inputPanel.backgroundColor = UIColor(OnymTokens.surface2)
        inputPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputPanel)

        inputPanelSeparator.backgroundColor = UIColor(OnymTokens.hairline)
        inputPanelSeparator.translatesAutoresizingMaskIntoConstraints = false
        inputPanel.addSubview(inputPanelSeparator)

        // Placeholder copy so the panel is visible during PR 5
        // without doing anything yet. PR 6 replaces the label with
        // a real UITextView + send button.
        inputPlaceholderLabel.text = "Message input lands in PR 6"
        inputPlaceholderLabel.font = .systemFont(ofSize: 14)
        inputPlaceholderLabel.textColor = UIColor(OnymTokens.text3)
        inputPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        inputPanel.addSubview(inputPlaceholderLabel)
    }

    // MARK: - Layout

    private func layout() {
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Top bar — pinned to the safe area, fixed 44pt height
            // (matches iOS nav bar default).
            topBar.topAnchor.constraint(equalTo: safeArea.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 36),
            backButton.heightAnchor.constraint(equalToConstant: 36),

            infoButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            infoButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 36),
            infoButton.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -8),

            topBarSeparator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            // Table view — fills the space between the top bar and
            // the input panel.
            tableView.topAnchor.constraint(equalTo: topBarSeparator.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputPanel.topAnchor),

            // Input panel — pinned to the safe-area bottom, fixed
            // 56pt height for PR 5. PR 6 swaps this for a layout
            // that grows with the text view (up to a 3-line cap).
            inputPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputPanel.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            inputPanel.heightAnchor.constraint(equalToConstant: 56),

            inputPanelSeparator.topAnchor.constraint(equalTo: inputPanel.topAnchor),
            inputPanelSeparator.leadingAnchor.constraint(equalTo: inputPanel.leadingAnchor),
            inputPanelSeparator.trailingAnchor.constraint(equalTo: inputPanel.trailingAnchor),
            inputPanelSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            inputPlaceholderLabel.leadingAnchor.constraint(equalTo: inputPanel.leadingAnchor, constant: 16),
            inputPlaceholderLabel.centerYAnchor.constraint(equalTo: inputPanel.centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func tappedBack() { onBack?() }
    @objc private func tappedInfo() { onShowMembers?() }
}

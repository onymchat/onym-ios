import Foundation
import SwiftUI
import OnymDesignTokens

/// Onym's Terms of Use — the end-user licence agreement every user
/// accepts on the welcome screen before reaching any chat.
///
/// Bump `version` whenever the text changes in substance: an accepted
/// older version no longer counts, so everyone is asked again.
public enum TermsOfUse {
    public static let version = 1

    public struct Section: Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let body: String
    }

    public static var sections: [Section] {
        [
            Section(id: 0, title: String(localized: "Agreement"), body: String(localized: """
            These Terms of Use are an agreement between you and Onym for your use of the Onym app. By checking “I agree” you accept them. If you don't agree, don't use Onym. The app is licensed to you, not sold, under these terms and Apple's Licensed Application End User License Agreement.
            """)),
            Section(id: 1, title: String(localized: "No tolerance for objectionable content or abusive users"), body: String(localized: """
            Onym has zero tolerance for objectionable content and abusive behaviour. You must not send, share or store through Onym:
            • child sexual abuse material, or anything sexualising minors;
            • harassment, bullying, threats or intimidation;
            • hate speech, or content promoting violence or terrorism;
            • sexual content shared without the consent of the people in it;
            • fraud, scams, spam, malware, or anything illegal where you or the recipient live.
            Breaking this rule ends your right to use Onym.
            """)),
            Section(id: 2, title: String(localized: "Reporting and blocking"), body: String(localized: """
            Long-press any message to report it. The report goes to your chosen moderation authority with the message as evidence, signed by its sender so it can't be forged.
            Long-press a message, or a person in a chat's member list, to block them. Their messages disappear from your chats at once, new ones never reach you, and blocking from a message takes you straight to reporting it to the moderators.
            """)),
            Section(id: 3, title: String(localized: "What happens to reports"), body: String(localized: """
            Reports are reviewed within 24 hours. Content that breaks these terms is removed, and the user who sent it is banned from the moderation authority and the groups that rely on it. Material that the law requires to be reported to the authorities is reported.
            """)),
            Section(id: 4, title: String(localized: "Privacy"), body: String(localized: """
            Messages are end-to-end encrypted: nobody but the people in a chat can read them — not Onym, and not the relays that carry them. The only exception is a message you choose to report, which you disclose to the moderators yourself.
            """)),
            Section(id: 5, title: String(localized: "Contact"), body: String(localized: """
            Questions, or something the in-app tools can't handle: hello@onym.app.
            """)),
        ]
    }
}

/// Whether the current Terms of Use version was accepted on this device.
/// `@unchecked Sendable`: UserDefaults is thread-safe but not `Sendable`.
public struct TermsAcceptance: @unchecked Sendable {
    static let versionKey = "app.onym.ios.terms.acceptedVersion"
    static let dateKey = "app.onym.ios.terms.acceptedAt"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isAccepted: Bool {
        defaults.integer(forKey: Self.versionKey) >= TermsOfUse.version
    }

    public func accept(at date: Date = Date()) {
        defaults.set(TermsOfUse.version, forKey: Self.versionKey)
        defaults.set(date, forKey: Self.dateKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.versionKey)
        defaults.removeObject(forKey: Self.dateKey)
    }
}

/// The full Terms of Use, readable before agreeing.
public struct TermsOfUseView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(TermsOfUse.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(OnymType.font(size: 17, weight: .semibold))
                            Text(section.body)
                                .font(OnymType.font(size: 15))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text("Terms of Use"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("terms.done")
                }
            }
        }
        .accessibilityIdentifier("terms.document")
    }
}

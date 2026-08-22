import OnymDesign
import SwiftUI

/// Settings → Notifications: one switch, off by default, and an honest
/// statement of the trade. Enabling push hands two parties something
/// the rest of the app avoids creating — Onym's push server learns
/// which inbox codes this device wants wakes for, and Apple carries a
/// content-free alert — so the copy says exactly that instead of
/// "enable notifications to stay connected".
public struct NotificationsSettingsView: View {
    @State private var flow: NotificationsSettingsFlow
    @State private var switchState: Bool

    public init(flow: NotificationsSettingsFlow) {
        _flow = State(initialValue: flow)
        _switchState = State(initialValue: flow.isEnabled)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    Toggle(isOn: $switchState) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Message Notifications")
                                .font(.body)
                            Text("Content-free alerts when a message arrives")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .disabled(flow.isWorking)
                    .accessibilityIdentifier("settings.notifications_toggle")
                }

                if flow.authorizationDenied {
                    SettingsFootnote(
                        "Notifications are blocked for Onym in system Settings. Allow them there, then turn this on again."
                    )
                }

                if flow.registrationPending {
                    SettingsFootnote(
                        "Activating\u{2026} the push server has not confirmed this device yet. Onym retries when you return to the app; check back if alerts don\u{2019}t arrive."
                    )
                }

                SettingsFootnote(
                    "How it works: an Onym-run push server watches your configured Nostr relays for your inbox codes and asks Apple to wake this device, a few seconds delayed at random. It never sees message content, senders, or groups — it holds only your inbox codes and an encrypted push token, and asks the server to forget both when you turn this off (retried until the server confirms). All of your identities\u{2019} inbox codes are registered together, so the push server can tell they belong to one device. The alert itself always reads \u{201C}New message\u{201D}; nothing about the conversation passes through Apple."
                )
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Registration completes off-screen, and the coordinator
            // can disable off-screen (authorization revoked in system
            // Settings); re-read so both render truthfully. The
            // onChange guard keeps this resync from re-driving the
            // flow.
            flow.refreshRegistrationState()
            switchState = flow.isEnabled
        }
        .onChange(of: switchState) { _, wanted in
            guard wanted != flow.isEnabled else { return }
            Task {
                await flow.setEnabled(wanted)
                switchState = flow.isEnabled
            }
        }
    }
}

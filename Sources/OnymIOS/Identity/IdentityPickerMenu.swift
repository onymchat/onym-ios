import SwiftUI

/// Top-bar leading dropdown on the Chats tab. Shows the currently-
/// selected identity's name (with a small `person.fill` glyph); tap to
/// pick another identity from the persisted list.
///
/// A no-op when only one identity exists — the menu's just a label
/// then. Once Settings → Identities → Add Identity ships a second one,
/// the menu becomes interactive automatically.
struct IdentityPickerMenu: View {
    @Bindable var flow: IdentitiesFlow

    var body: some View {
        Menu {
            ForEach(flow.identities, id: \.id) { summary in
                Button {
                    flow.select(summary.id)
                } label: {
                    HStack {
                        Text(summary.name)
                        if summary.id == flow.currentID {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier("identity_picker.row.\(summary.id)")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.subheadline)
                if flow.identities.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .foregroundStyle(Color.accentColor)
        }
        .accessibilityIdentifier("identity_picker.menu")
        .disabled(flow.identities.count < 2)
    }
}

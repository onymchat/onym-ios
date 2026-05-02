import Foundation

/// Composite key the user picks against — one selection per
/// (network, governance type) cell. Five governance types × two
/// networks = ten possible selection cells; most users will have
/// touched at most a handful explicitly, the rest fall back to
/// "default to latest".
struct AnchorSelectionKey: Codable, Equatable, Hashable, Sendable {
    let network: ContractNetwork
    let type: GovernanceType
}

/// The resolved triple a chat carries forever after creation. Reading
/// `chat.anchor.contractID` + `chat.anchor.network` is the only correct
/// way to update an *existing* chat's on-chain state — the picker's
/// current selection is for *new* chats only.
///
/// `release` is the human-readable release tag (`"v0.0.2"`) — kept
/// alongside the resolved contract id for display and audit. If the
/// user later changes their selection in Settings, this binding does
/// NOT change; it's pinned at chat-creation time.
struct AnchorBinding: Codable, Equatable, Hashable, Sendable {
    let network: ContractNetwork
    let governanceType: GovernanceType
    let contractID: String
    let release: String

    var key: AnchorSelectionKey {
        AnchorSelectionKey(network: network, type: governanceType)
    }
}

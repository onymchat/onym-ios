import Foundation

/// View-facing directory entry for one peer the local user has
/// interacted with through a group. Carries what the UI needs to
/// render "X joined" / "you are talking to Y" without crossing into
/// secret material. Stored on `ChatGroup.memberProfiles` keyed by
/// the peer's lowercase BLS pubkey hex.
///
/// Distinct from `GovernanceMember`: that's the on-chain Merkle-tree
/// roster (V1: creator only, static). `MemberProfile` covers the
/// app-level "who's in this conversation" set, which V1 grows as
/// joiners are admitted even though the on-chain roster doesn't
/// change.
///
/// Trust: `alias` is self-asserted by its owner — never load-bearing.
/// Surfaces should always offer the member's BLS-pubkey fingerprint
/// alongside (matches the inviter-approval pattern documented on
/// `JoinRequestPayload`).
///
/// `inboxPublicKey` is the 32-byte X25519 raw pub. Persisted so the
/// admin (or any authorized fanout sender, in future governance
/// models) can reach every member's inbox to announce roster changes
/// without re-deriving from the join request each time.
struct MemberProfile: Codable, Equatable, Hashable, Sendable {
    let alias: String
    let inboxPublicKey: Data
}

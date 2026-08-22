import CryptoKit
import Foundation

/// The inbox routing tag: first 8 bytes, lowercase hex, of
/// `SHA256("sep-inbox-v1" || inboxPublicKey)`.
///
/// This is the one formula behind every `inboxTag(from:)` helper —
/// hoisted here so senders, subscribers, the identity repository, and
/// the push registration all derive the same tag from the same bytes.
/// A pure function of the public key: the tag is a *public* routing
/// handle, already visible to every relay carrying the inbox.
public enum InboxTag {
    public static func derive(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

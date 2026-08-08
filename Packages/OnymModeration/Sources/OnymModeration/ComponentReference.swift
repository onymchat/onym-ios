import Foundation

/// The spec's component-reference form, `onym:component:<identifier>` —
/// how manifests, mandates, and verdicts name authorities, interfaces,
/// and appellates.
///
/// A parser rather than a prefix check, for the same reason
/// `AuthorityKey` is one: `hasPrefix("onym:component:")` accepts the
/// bare prefix, so `"onym:component:"` would pass as an appellate while
/// naming nobody. A reference this client can't resolve to an
/// identifier is not a component it can bind consent to.
public enum ComponentReference {
    public static let prefix = "onym:component:"

    /// The identifier following the prefix.
    ///
    /// - Throws: `ModerationError.componentReferenceInvalid` when the
    ///   prefix is absent, or the identifier is empty or blank —
    ///   whitespace names no component either.
    public static func identifier(from reference: String) throws -> String {
        guard reference.hasPrefix(prefix) else {
            throw ModerationError.componentReferenceInvalid("not an \(prefix) reference: \(reference)")
        }
        let identifier = String(reference.dropFirst(prefix.count))
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModerationError.componentReferenceInvalid("\(prefix) reference names no component")
        }
        guard !identifier.contains(where: \.isWhitespace) else {
            throw ModerationError.componentReferenceInvalid("\(prefix) identifier contains whitespace")
        }
        return identifier
    }

    /// Whether two references name the same component. Parses both, so
    /// a malformed reference is never "different from" anything by
    /// accident.
    public static func namesSameComponent(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = try? identifier(from: lhs), let right = try? identifier(from: rhs) else {
            return false
        }
        return left == right
    }

    public static func reference(for identifier: String) -> String {
        prefix + identifier
    }
}

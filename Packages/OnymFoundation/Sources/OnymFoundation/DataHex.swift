import Foundation

public extension Data {
    /// Lowercase hex.
    ///
    /// Hoisted here from `OnymGroup`, whose copy carried a note about
    /// four hand-rolled `%02x` loops and a fifth about to be written.
    /// The treasury layer then wrote the sixth and seventh — in two
    /// different packages, one of them `private` so the other could not
    /// see it. Every package above `OnymFoundation` can reach this one.
    ///
    /// Lowercase is not cosmetic: BLS pubkey hex is the key type for
    /// `ChatGroup.memberProfiles`, and a dictionary lookup with the
    /// other case silently finds nothing.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

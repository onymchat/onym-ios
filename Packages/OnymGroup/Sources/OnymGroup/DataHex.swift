import Foundation

extension Data {
    /// Lowercase hex. One implementation, because there were four
    /// hand-rolled `%02x` loops in this package and a fifth was about
    /// to be written.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

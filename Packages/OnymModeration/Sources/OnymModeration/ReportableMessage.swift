import Foundation

/// A recipient-held message that can be disclosed to an Authority.
/// `disclosedContent` is the canonical proof preimage — the message
/// body bound to its message id, group id, and send timestamp — and
/// `authenticityProof` is the sender's Ed25519 signature over its exact
/// UTF-8 bytes; the Authority independently verifies it against
/// `accused` before the content can support a case. `displayBody` is
/// the bare body, for showing the user what they are disclosing.
public struct ReportableMessage: Sendable, Equatable, Identifiable {
    /// A received photo the reporter is disclosing along with the
    /// message.
    ///
    /// The bytes are carried here rather than fetched at submit time
    /// because they are the *decrypted* attachment the recipient
    /// already holds: the report screen shows exactly these, and
    /// exactly these are uploaded. Anything re-fetched between showing
    /// and sending could differ from what the user agreed to disclose.
    public struct Image: Sendable, Equatable {
        /// SHA-256 of `bytes` — and the digest the sender signed, so it
        /// is both the upload's address and its authenticity binding.
        public let sha256: String
        public let bytes: Data
        public let width: Int
        public let height: Int

        public init(sha256: String, bytes: Data, width: Int, height: Int) {
            self.sha256 = sha256
            self.bytes = bytes
            self.width = width
            self.height = height
        }
    }

    public let id: String
    public let accused: String
    public let disclosedContent: String
    public let authenticityProof: String
    public let displayBody: String
    /// The disclosed photo, when this is a photo message. Empty for a
    /// text report.
    public let images: [Image]

    public init(
        id: String,
        accused: String,
        disclosedContent: String,
        authenticityProof: String,
        displayBody: String,
        images: [Image] = []
    ) {
        self.id = id
        self.accused = accused
        self.disclosedContent = disclosedContent
        self.authenticityProof = authenticityProof
        self.displayBody = displayBody
        self.images = images
    }
}

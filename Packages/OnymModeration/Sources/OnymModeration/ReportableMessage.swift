import Foundation

/// A recipient-held text message that can be disclosed to an Authority.
/// `disclosedContent` is the canonical proof preimage — the message
/// body bound to its message id, group id, and send timestamp — and
/// `authenticityProof` is the sender's Ed25519 signature over its exact
/// UTF-8 bytes; the Authority independently verifies it against
/// `accused` before the content can support a case. `displayBody` is
/// the bare body, for showing the user what they are disclosing.
public struct ReportableMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let accused: String
    public let disclosedContent: String
    public let authenticityProof: String
    public let displayBody: String

    public init(
        id: String,
        accused: String,
        disclosedContent: String,
        authenticityProof: String,
        displayBody: String
    ) {
        self.id = id
        self.accused = accused
        self.disclosedContent = disclosedContent
        self.authenticityProof = authenticityProof
        self.displayBody = displayBody
    }
}

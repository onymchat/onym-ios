import Foundation

/// A recipient-held text message that can be disclosed to an Authority.
/// The proof is the sender's Ed25519 signature over the exact UTF-8 bytes
/// of `disclosedContent`; the Authority independently verifies it against
/// `accused` before the content can support a case.
public struct ReportableMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let accused: String
    public let disclosedContent: String
    public let authenticityProof: String

    public init(
        id: String,
        accused: String,
        disclosedContent: String,
        authenticityProof: String
    ) {
        self.id = id
        self.accused = accused
        self.disclosedContent = disclosedContent
        self.authenticityProof = authenticityProof
    }
}

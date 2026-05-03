import Foundation
@testable import OnymIOS

/// `InvitationEnvelopeDecrypting` test double. Two modes:
///
/// - `.fixed(plaintext)` — every call returns the same plaintext bytes,
///   useful for asserting the interactor's pump shape without caring
///   about the envelope contents.
/// - `.scripted(byEnvelope: [Data: Data])` — match input bytes to a
///   specific plaintext, so a single test can drive multiple distinct
///   invitations through the interactor and assert each maps correctly.
/// - `.failing(error)` — every call throws, for error-path coverage.
///
/// Tracks every received envelope in `decryptCalls` so tests can assert
/// what the interactor actually fed to the decrypter.
actor FakeInvitationEnvelopeDecrypter: InvitationEnvelopeDecrypting {
    enum Mode: Sendable {
        case fixed(Data)
        case scripted([Data: Data])
        case failing(InvitationDecryptError)
    }

    private let mode: Mode
    private(set) var decryptCalls: [(envelopeBytes: Data, identityID: IdentityID)] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func decryptInvitation(envelopeBytes: Data, asIdentity identityID: IdentityID) throws -> Data {
        decryptCalls.append((envelopeBytes, identityID))
        switch mode {
        case .fixed(let plaintext):
            return plaintext
        case .scripted(let table):
            guard let plaintext = table[envelopeBytes] else {
                throw InvitationDecryptError.malformedEnvelope
            }
            return plaintext
        case .failing(let error):
            throw error
        }
    }
}

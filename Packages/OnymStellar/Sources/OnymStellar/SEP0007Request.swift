import Foundation

/// A SEP-0007 `tx` request — the standard way to hand an unsigned
/// transaction to whatever Stellar wallet a person already uses.
///
/// This is how a participant who keeps their account outside Onym signs:
/// the app never sees their key, and the wallet never sees the chat.
///
/// ## Percent-encoding is the whole problem
///
/// The payload is base64, whose alphabet includes `+`, `/` and `=`. All
/// three are legal in a URL query *component* and all three are
/// misread: `+` is decoded as a space by essentially every form-style
/// parser, `/` reads as a path separator to naive splitters, and `=`
/// ends the key. `URLComponents.queryItems` does not escape `+`, so
/// building the query through it produces a URL that works until a
/// wallet's parser normalises spaces — at which point the XDR is
/// corrupt and the failure surfaces as an unreadable transaction rather
/// than as an encoding bug. The query here is therefore assembled by
/// hand against an explicit allowed set.
///
/// ## What is deliberately not sent
///
/// `callback` is omitted, and so is `origin_domain` — see its note.
/// SEP-0007 defines `callback` as an HTTPS endpoint the
/// wallet POSTs the signed envelope to, which would mean running a
/// server that receives other people's transactions. The signed
/// transaction comes back by one of the three routes the signing screen
/// offers instead — the wallet submitting it directly, a return link,
/// or paste.
public struct SEP0007Request: Equatable, Sendable {
    /// The spec's cap on `msg`, in characters.
    public static let maxMessageLength = 300

    public let envelope: TransactionEnvelope
    public let network: StellarNetwork
    /// Short human-readable purpose shown by the wallet. Truncated to
    /// `maxMessageLength` at build time — a wallet that rejects an
    /// over-long request would strand the signer with no way to act.
    public let message: String?
    /// The account the request is meant for. Wallets holding several
    /// accounts use it to preselect the right one.
    public let publicKey: StellarAccountID?
    /// Defaults to **nil**, and should stay that way until requests are
    /// signed.
    ///
    /// SEP-0007 pairs `origin_domain` with a `signature` the wallet
    /// verifies against the domain's stellar.toml. Sending the claim
    /// without the signature is an assertion no wallet can check;
    /// several warn about it and some refuse the request outright. An
    /// unverifiable claim of provenance is worth less than no claim.
    public let originDomain: String?

    public init(
        envelope: TransactionEnvelope,
        network: StellarNetwork,
        message: String? = nil,
        publicKey: StellarAccountID? = nil,
        originDomain: String? = nil
    ) {
        self.envelope = envelope
        self.network = network
        self.message = message
        self.publicKey = publicKey
        self.originDomain = originDomain
    }

    /// Everything except the unreserved set gets escaped. Narrower than
    /// `.urlQueryAllowed`, which permits `+`, `/`, `=`, `&` and `?`
    /// precisely because they are query *syntax* — and the values here
    /// are data, not syntax.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public var url: URL? {
        var items: [(String, String)] = [("xdr", envelope.base64XDR)]
        // Always sent, including for the public network. The spec makes
        // it optional with pubnet as the default, but a wallet that
        // guesses wrong signs against a different network id and
        // produces a signature that verifies nowhere.
        items.append(("network_passphrase", network.passphrase))
        if let message, !message.isEmpty {
            items.append(("msg", String(message.prefix(Self.maxMessageLength))))
        }
        if let publicKey {
            items.append(("pubkey", publicKey.accountID))
        }
        if let originDomain, !originDomain.isEmpty {
            items.append(("origin_domain", originDomain))
        }
        // `compactMap` would drop an item that failed to escape and
        // still hand back a URL. For `msg` or `pubkey` that is a
        // degraded request; for `xdr` it is a wallet opening a signing
        // screen with no transaction in it, which is the one outcome
        // worth failing over. Nothing to escape here can legitimately
        // return nil, so a nil is a bug rather than a user's input —
        // and the honest response to a bug on this path is no URL.
        var escapedItems: [String] = []
        for (key, value) in items {
            guard let escaped = value.addingPercentEncoding(
                withAllowedCharacters: Self.unreserved
            ) else { return nil }
            escapedItems.append("\(key)=\(escaped)")
        }
        return URL(string: "web+stellar:tx?\(escapedItems.joined(separator: "&"))")
    }

    /// Read a signed envelope out of a return URL (`onym://tx?xdr=…`).
    ///
    /// Returns the envelope only — deliberately not a "this is now the
    /// proposal" result. The caller must feed it to
    /// `TransactionEnvelope.harvestSignatures(from:candidates:network:)`,
    /// which keeps the signatures and throws the returned transaction
    /// away. Parsing it here into anything more authoritative would
    /// invite a caller to adopt a body a wallet chose.
    public static func envelope(fromReturnURL url: URL) throws -> TransactionEnvelope {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "xdr" })?.value
        else {
            throw SEP0007Error.missingXDR
        }
        // `URLComponents` has already percent-decoded the value. It does
        // not undo form-style `+`-as-space, and base64 legitimately
        // contains `+`, so the value is used as-is.
        return try TransactionEnvelope(base64XDR: raw)
    }
}

public enum SEP0007Error: Error, Equatable, Sendable {
    case missingXDR
}

import Foundation

/// Build-time bundled secrets for the relayer. Today this is just the
/// Bearer auth token the relayer requires (`Authorization: Bearer …`,
/// see `onym-relayer/src/validation.rs::validate_auth`).
///
/// ## Source
///
/// `Resources/RelayerSecrets.json` — gitignored. Two paths populate it:
///
/// - **Local dev**: copy `RelayerSecrets.example.json` to
///   `RelayerSecrets.json` and paste the dev token. Without this file
///   the app builds fine but every relayer call returns 401.
/// - **Release CI**: `release.yml` writes the file from the repo's
///   `RELAYER_AUTH_TOKEN` secret before xcodegen runs, so the IPA
///   ships with the right value.
///
/// ## Why a JSON file (not xcconfig / Info.plist)
///
/// The xcconfig path requires xcodegen wiring + an Info.plist key +
/// a runtime accessor. A bundled JSON is one file with one parser —
/// fewer moving parts when the secret needs to grow (e.g. add a
/// per-network token map later).
enum RelayerSecrets {
    private struct Schema: Decodable {
        let authToken: String?
    }

    /// Optional Bearer token to send with every relayer POST. `nil`
    /// when `RelayerSecrets.json` is missing or its `authToken` field
    /// is empty (so contributors can build without the secret —
    /// requests will just 401 and the create-group flow surfaces a
    /// clean error).
    static let authToken: String? = {
        guard let url = Bundle.main.url(
            forResource: "RelayerSecrets",
            withExtension: "json"
        ) else { return nil }
        guard
            let data = try? Data(contentsOf: url),
            let schema = try? JSONDecoder().decode(Schema.self, from: data)
        else { return nil }
        guard let token = schema.authToken, !token.isEmpty else { return nil }
        return token
    }()
}

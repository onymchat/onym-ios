import Foundation

/// One JSON decode configuration for every moderation wire response.
/// RFC 3339 permits fractional seconds; Foundation's built-in
/// `.iso8601` strategy accepts only the whole-second form, so both
/// shapes are tried. The formatters are built once — this decoder is
/// hit for every date in every gate check and status fetch.
enum ModerationJSON {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = fractional.date(from: value) ?? wholeSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected an RFC 3339 timestamp"
            )
        }
        return decoder
    }
}

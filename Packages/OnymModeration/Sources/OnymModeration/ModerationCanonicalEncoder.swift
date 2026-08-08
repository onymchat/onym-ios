import Foundation

/// The one encoder configuration every moderation signing form uses.
///
/// Two settings, both load-bearing:
///
/// - **`.sortedKeys`** — `JSONEncoder` sorts keys by UTF-8 byte order.
///   Beware that `JSONSerialization` has an option of the same name
///   that sorts *case-insensitively*; the two disagree whenever keys
///   differ by case at the deciding character. Among the moderation
///   objects, `Report` is the one where that actually bites
///   (`reportId`/`reportVersion` versus `reporter`), so signing bytes
///   must never be produced through `JSONSerialization`.
/// - **`.iso8601` dates** — seconds precision, UTC, matching the form
///   every timestamp crosses the wire in.
///
/// Byte order is also what every non-Apple JSON library does by
/// default (serde_json, Go's `encoding/json`, Python's `sort_keys`),
/// which is what lets an authority written in another language
/// reconstruct these bytes at all.
///
/// PROVISIONAL: the draft spec fixes no canonical JSON form. When it
/// does, this is the single place that changes — and objects signed
/// before then will need re-signing.
enum ModerationCanonicalEncoder {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

import Foundation

/// Persistence seam for both the user's per-(network, type)
/// version selections and the cached `ContractsManifest`. Same
/// shape as `RelayerSelectionStore` from PR #18.
///
/// Selections are stored as a JSON-encoded `[AnchorSelectionKey:
/// String]` dictionary. UserDefaults can't natively persist a
/// `[Hashable: ...]` map, so we serialise to a single `Data` blob.
protocol AnchorSelectionStore: Sendable {
    func loadSelections() -> [AnchorSelectionKey: String]
    func saveSelections(_ selections: [AnchorSelectionKey: String])

    func loadCachedManifest() -> ContractsManifest?
    func saveCachedManifest(_ manifest: ContractsManifest)
}

/// Production `AnchorSelectionStore`. UserDefaults-backed (no secret
/// material). Suite-name injectable for per-test isolation.
struct UserDefaultsAnchorSelectionStore: AnchorSelectionStore, @unchecked Sendable {
    private static let selectionsKey = "app.onym.ios.anchors.selections"
    private static let manifestKey = "app.onym.ios.anchors.cachedManifest"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSelections() -> [AnchorSelectionKey: String] {
        guard let data = defaults.data(forKey: Self.selectionsKey),
              let entries = try? JSONDecoder().decode([SelectionEntry].self, from: data)
        else { return [:] }
        var result: [AnchorSelectionKey: String] = [:]
        for entry in entries {
            result[entry.key] = entry.releaseTag
        }
        return result
    }

    func saveSelections(_ selections: [AnchorSelectionKey: String]) {
        let entries = selections.map { SelectionEntry(key: $0.key, releaseTag: $0.value) }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.selectionsKey)
        } else {
            defaults.removeObject(forKey: Self.selectionsKey)
        }
    }

    func loadCachedManifest() -> ContractsManifest? {
        guard let data = defaults.data(forKey: Self.manifestKey),
              let manifest = try? JSONDecoder.iso8601().decode(ContractsManifest.self, from: data)
        else { return nil }
        return manifest
    }

    func saveCachedManifest(_ manifest: ContractsManifest) {
        guard let data = try? JSONEncoder.iso8601().encode(manifest) else { return }
        defaults.set(data, forKey: Self.manifestKey)
    }
}

/// Round-trip wrapper so we can serialise the dictionary as a JSON
/// array (dictionaries with non-String keys aren't natively
/// `Codable`-friendly to JSON).
private struct SelectionEntry: Codable {
    let key: AnchorSelectionKey
    let releaseTag: String
}

extension JSONDecoder {
    /// Decoder configured for ISO-8601 dates (the wire format the
    /// GitHub Releases API and the manifest both use).
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

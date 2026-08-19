import Foundation

/// Padmé bucketing, so a snapshot's size on the wire is a coarse bucket
/// rather than a measurement of a person's history
/// (`UI-Backup-Object-HTTP.md` §7).
///
/// For a length `L`, let `E = floor(log2(L))` and `S = floor(log2(E)) + 1`;
/// round `L` up to the next multiple of `2^(E - S)`. Overhead is capped
/// at about 12%.
///
/// A power-of-two ladder would leak less and can double the stored
/// bytes. Storage here is already linear in holders and undeduplicable
/// by design — §5.3 forbids convergent keying — so doubling it to
/// sharpen an already-coarse signal is the wrong trade.
///
/// The operator sees the padded size and cannot avoid seeing it. What it
/// must not do is keep a series of them per holder, which §15 forbids
/// and only the operator's own conduct enforces.
public enum BackupPadding {
    /// The padded length for `length`. Never shorter than the input.
    public static func paddedLength(for length: Int) -> Int {
        // Below 2 bytes there is no exponent to work with, and nothing
        // that small is a real archive anyway.
        guard length > 1 else { return max(length, 0) }
        let e = highestBitPosition(length) - 1     // floor(log2(length))
        guard e > 0 else { return length }
        let s = highestBitPosition(e)              // floor(log2(e)) + 1
        let bits = e - s
        guard bits > 0 else { return length }
        let step = 1 << bits
        let remainder = length % step
        return remainder == 0 ? length : length + (step - remainder)
    }

    /// How many zero bytes `paddedLength(for:)` appends.
    public static func paddingCount(for length: Int) -> Int {
        paddedLength(for: length) - length
    }
}

/// `floor(log2(x)) + 1` for a positive Int — the position of the highest
/// set bit. Spelled out rather than calling the C `flsl`, whose name is
/// already in scope through Foundation and resolves ambiguously here.
private func highestBitPosition(_ value: Int) -> Int {
    value <= 0 ? 0 : Int.bitWidth - value.leadingZeroBitCount
}

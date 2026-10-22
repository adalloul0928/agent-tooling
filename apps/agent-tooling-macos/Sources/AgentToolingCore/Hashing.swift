import Foundation

extension Sequence where Element == UInt8 {
    /// The bytes as lowercase, two-digit, full-width hexadecimal with no
    /// separator — the one ending every SHA-256 digest in this package shares.
    /// A digest, a `hasher.finalize()`, or a `.prefix(n)` of either all conform,
    /// so a truncated hash keeps its prefix by slicing before this call.
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

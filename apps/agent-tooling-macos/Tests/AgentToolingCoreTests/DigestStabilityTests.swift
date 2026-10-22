import AgentToolingTestSupport
import CryptoKit
import Foundation
import Testing

@testable import AgentToolingCore

/// Pins the exact bytes of the digests and object identities that the
/// core-reuse cleanup routes through shared helpers. These values are persisted
/// in the portable document and compared across Macs, so a refactor that is
/// meant to leave behaviour unchanged must keep every string here identical.
/// The expected values were captured against the code before the shared helpers
/// existed; they must survive the extraction unchanged.
@Suite("Digest stability")
struct DigestStabilityTests {
    // Fixed identities so the digest inputs never vary between runs.
    private static let revision = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000001"))
    private static let idempotency = WorkspaceObjectID(fixtureUUID("00000000-0000-0000-0000-000000000002"))
    private static let preset = ArtifactID(fixtureUUID("00000000-0000-0000-0000-000000000003"))
    private static let member = ArtifactID(fixtureUUID("00000000-0000-0000-0000-000000000004"))

    // MARK: - D3 one SHA-256 hex helper

    /// The hex ending is `.map { String(format: "%02x", $0) }.joined()` on a
    /// `SHA256` digest. Pin a fixed input's hex so the shared helper keeps the
    /// same lowercase, two-digit, full-width encoding.
    @Test func sha256HexEndingIsStable() {
        let digest = SHA256.hash(data: Data("agent-tooling golden".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "3819563af3fac61bc08217ea5b4878edf080095149ea29976a962cfa84534ce7")
    }

    /// The `.prefix(n)` sites keep their prefix before the hex ending, so pin
    /// a truncated encoding too.
    @Test func sha256HexPrefixIsStable() {
        let digest = SHA256.hash(data: Data("agent-tooling golden".utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "3819563af3fac61b")
    }

    // MARK: - D2 framed digest (|-joined, length-prefixed, NFC)

    /// `CreatePresetCommand.inputDigest()` builds the `|`-joined length-prefixed
    /// framed digest. Pin it for a fully fixed command so the shared framed
    /// helper reproduces the exact persisted idempotency digest.
    @Test func framedDigestIsStable() throws {
        let command = try CreatePresetCommand(
            expectedRevisionID: Self.revision,
            idempotencyKey: Self.idempotency,
            presetID: Self.preset,
            name: "Golden Preset",
            memberArtifactIDs: [Self.member])
        #expect(command.inputDigest() == "aad2a250f84b31a00169c255a99acc8a414d5afb1f246c9d9059d04efebb93a0")
    }

    // MARK: - D1 UUIDv8-from-SHA-256 allocator tail

    /// `AccountPreferenceKey.objectID` derives a version-8 object ID from its
    /// own byte framing. Pin it so the shared allocator tail keeps the account
    /// key's persisted identity byte for byte.
    @Test func accountPreferenceKeyObjectIDIsStable() {
        let key = AccountPreferenceKey(.connector, subject: "Google Calendar")
        #expect(key.objectID.rawValue.uuidString.lowercased() == "d2fb6e05-46ad-82f5-8e3d-17023bd1dbe9")
    }

    /// The shared allocator tail stamps the UUIDv8 version/variant nibbles over
    /// the first 16 digest bytes. Pin the mapping from a fixed 16-byte digest to
    /// its UUID so both call sites keep producing the same identity.
    @Test func uuidV8AllocatorTailIsStable() {
        let digest = Array(SHA256.hash(data: Data("agent-tooling allocator golden".utf8)).prefix(16))
        var stamped = digest
        stamped[6] = (stamped[6] & 0x0F) | 0x80
        stamped[8] = (stamped[8] & 0x3F) | 0x80
        let uuid = UUID(
            uuid: (
                stamped[0], stamped[1], stamped[2], stamped[3], stamped[4], stamped[5], stamped[6], stamped[7],
                stamped[8], stamped[9], stamped[10], stamped[11], stamped[12], stamped[13], stamped[14], stamped[15]
            ))
        #expect(uuid.uuidString.lowercased() == "84fa26ec-c9b1-8bff-9cc7-7d06c06d1f02")
    }
}

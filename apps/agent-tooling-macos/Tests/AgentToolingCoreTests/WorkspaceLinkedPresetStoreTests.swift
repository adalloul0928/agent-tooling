import Foundation
import Testing

@testable import AgentToolingCore

/// Which presets this Mac follows. A file this build cannot read is an error,
/// never "nothing is linked" — that would look like the person unlinked
/// everything and the next catch-up would act on it.
@Suite("Workspace linked preset store")
struct WorkspaceLinkedPresetStoreTests {
    @Test func aSavedSubscriptionSurvivesReopening() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let subscription = LinkedPresetSubscription(
            presetID: Self.presetID, appliedRevision: 3,
            destinations: [.init(surface: .codexCLI, scope: .user)])

        try fixture.store.write([subscription])

        #expect(try WorkspaceLinkedPresetStore(containerRoot: fixture.root).read() == [subscription])
    }

    @Test func aWorkspaceWithNothingLinkedReadsAsNothingLinked() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.store.read().isEmpty)
    }

    @Test func aDamagedFileIsAnErrorRatherThanAnEmptyAnswer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{ not json".utf8).write(to: fixture.file)

        #expect(throws: WorkspaceLinkedPresetStoreError.unsupportedFormat) {
            _ = try fixture.store.read()
        }
    }

    @Test func aFormatThisBuildDoesNotKnowIsRefusedRatherThanGuessedAt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"formatVersion":99,"subscriptions":[]}"#.utf8).write(to: fixture.file)

        #expect(throws: WorkspaceLinkedPresetStoreError.unsupportedFormat) {
            _ = try fixture.store.read()
        }
    }

    @Test func onePresetCannotBeFollowedTwice() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let codex = PortableDestination(surface: .codexCLI, scope: .user)
        let claude = PortableDestination(surface: .claudeCode, scope: .user)

        // Two subscriptions to one preset would each think they own the same
        // contributions and would take turns undoing each other.
        #expect(throws: WorkspaceLinkedPresetStoreError.unsupportedFormat) {
            try fixture.store.write([
                .init(presetID: Self.presetID, appliedRevision: 1, destinations: [codex]),
                .init(presetID: Self.presetID, appliedRevision: 2, destinations: [claude]),
            ])
        }
    }

    @Test func aFileWithMoreSubscriptionsThanCouldBeRealIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let subscriptions = (0..<(WorkspaceLinkedPresetStore.maximumSubscriptions + 1)).map { _ in
            LinkedPresetSubscription(presetID: ArtifactID(), appliedRevision: 1,
                                     destinations: [.init(surface: .codexCLI, scope: .user)])
        }

        #expect(throws: WorkspaceLinkedPresetStoreError.tooManySubscriptions) {
            try fixture.store.write(subscriptions)
        }
    }

    @Test func theFileIsReadableOnlyByThePersonWhoOwnsIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.write([.init(presetID: Self.presetID, appliedRevision: 1,
                                       destinations: [.init(surface: .codexCLI, scope: .user)])])

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }

    private static let presetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)

    private struct Fixture {
        let root: URL
        let store: WorkspaceLinkedPresetStore
        var file: URL { root.appending(path: "linked-presets.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "linked-preset-store-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            store = try WorkspaceLinkedPresetStore(containerRoot: root)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

import Darwin
import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct WorkspaceSkillCommandTests {
    @Test func intakeRetainsCompletePersonalTreeAndMakesItReadable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepared = try personalSkill("first")
        let artifactID = ArtifactID()
        let command = StandaloneSkillIntakeCommand(
            expectedRevisionID: fixture.document.revision.id,
            artifactID: artifactID,
            displayName: "First skill",
            aliases: [.init(namespace: "legacy.skill", value: "first")],
            prepared: prepared)

        let receipt = try await fixture.service.intakeStandaloneSkill(command, prepared: prepared)
        let saved = try #require(try fixture.store.snapshot())
        let artifact = try #require(saved.document.artifacts.first)
        #expect(artifact.identity.id == artifactID)
        #expect(artifact.authority == .centralPersonal)
        #expect(artifact.contentDigest == prepared.tree.digest)
        #expect(artifact.declaredName == prepared.frontmatter.name)
        let content = try await fixture.service.skillContent(artifactID: artifactID, revisionID: receipt.committedRevisionID)
        #expect(content.tree == prepared.tree)
        #expect(content.tree.entries.contains { $0.relativePath == "resources" && $0.kind == .directory })
        #expect(content.tree.entries.contains { $0.relativePath == "empty" && $0.kind == .directory })
        #expect(content.tree.entries.contains { $0.relativePath == "bin/run" && $0.kind == .file(bytes: Data("first".utf8), executable: true) })
        #expect(content.tree.entries.contains { $0.relativePath == "current" && $0.kind == .symbolicLink(target: "bin/run") })
    }

    @Test func personalUpdatePreservesIdentityLabelAliasesAssignmentsAndPriorContent() async throws {
        let first = try personalSkill("first")
        let second = try personalSkill("second")
        let artifactID = ArtifactID()
        let assignment = AssignmentContribution(
            artifactID: artifactID,
            destination: .init(surface: .codexCLI, scope: .user),
            reason: .manual,
            desiredPresence: true,
            desiredEnabled: nil)
        let fixture = try Fixture(document: initialDocument(
            artifactID: artifactID,
            content: first,
            aliases: [.init(namespace: "legacy.skill", value: "first")],
            assignments: [assignment]))
        defer { fixture.remove() }
        _ = try await fixture.contentStore.store(first.tree)
        let command = StandaloneSkillUpdateCommand(
            expectedRevisionID: fixture.document.revision.id,
            artifactID: artifactID,
            expectedContentDigest: first.tree.digest,
            prepared: second)

        let receipt = try await fixture.service.updateStandaloneSkill(command, prepared: second)
        let saved = try #require(try fixture.store.snapshot())
        let artifact = try #require(saved.document.artifacts.first)
        #expect(artifact.identity.id == artifactID)
        #expect(artifact.identity.displayName == "Reviewed label")
        #expect(artifact.identity.aliases == [.init(namespace: "legacy.skill", value: "first")])
        #expect(saved.document.assignments == [assignment])
        #expect(artifact.contentDigest == second.tree.digest)
        #expect(try await fixture.service.skillContent(artifactID: artifactID, revisionID: fixture.document.revision.id).tree == first.tree)
        #expect(try await fixture.service.skillContent(artifactID: artifactID, revisionID: receipt.committedRevisionID).tree == second.tree)
    }

    @Test func staleReuseAndReplayDoNotOverwriteIntakeMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try personalSkill("first")
        let second = try personalSkill("second")
        let artifactID = ArtifactID()
        let key = WorkspaceObjectID()
        let command = StandaloneSkillIntakeCommand(
            expectedRevisionID: fixture.document.revision.id,
            idempotencyKey: key,
            artifactID: artifactID,
            displayName: "First skill",
            prepared: first)
        let receipt = try await fixture.service.intakeStandaloneSkill(command, prepared: first)
        let reused = StandaloneSkillIntakeCommand(
            expectedRevisionID: fixture.document.revision.id,
            idempotencyKey: key,
            artifactID: artifactID,
            displayName: "Different label",
            prepared: second)
        await #expect(throws: WorkspaceRevisionStoreError.idempotencyKeyReused) {
            _ = try await fixture.service.intakeStandaloneSkill(reused, prepared: second)
        }
        let stale = StandaloneSkillIntakeCommand(
            expectedRevisionID: fixture.document.revision.id,
            artifactID: ArtifactID(),
            displayName: "Stale skill",
            prepared: second)
        await #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try await fixture.service.intakeStandaloneSkill(stale, prepared: second)
        }

        _ = try fixture.store.commitMetadata(
            expectedRevisionID: receipt.committedRevisionID,
            idempotencyKey: WorkspaceObjectID(),
            inputDigest: String(repeating: "a", count: 64),
            writerID: fixture.writerID
        ) { document in
            document.artifacts[0].identity.displayName = "Later label"
            return [artifactID]
        }
        let reopenedStore = try fixture.reopenStore()
        let reopened = WorkspaceApplicationService(store: reopenedStore, writerID: fixture.writerID)
        let replay = try await reopened.intakeStandaloneSkill(command, prepared: first)
        #expect(replay == receipt)
        #expect(try reopenedStore.snapshot()?.document.artifacts.first?.identity.displayName == "Later label")
    }

    @Test func reviewMismatchAndUnsupportedAuthoritiesRefuseBeforeWritingARevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try personalSkill("first")
        let second = try personalSkill("second")
        let mismatch = StandaloneSkillIntakeCommand(
            expectedRevisionID: fixture.document.revision.id, displayName: "Mismatch", prepared: first)
        await #expect(throws: WorkspaceSkillCommandError.reviewMismatch) {
            _ = try await fixture.service.intakeStandaloneSkill(mismatch, prepared: second)
        }
        #expect(try fixture.store.snapshot()?.document == fixture.document)

        let parentID = ArtifactID()
        let childID = ArtifactID()
        let native = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            workspaceID: WorkspaceObjectID(),
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [
                .init(identity: .init(id: parentID, kind: .nativePlugin, displayName: "Native"), authority: .nativeOwned,
                      nativeRoutes: [.init(client: .codex, externalPluginID: "native")]),
                .init(identity: .init(id: childID, kind: .skill, displayName: "Native child", parentPackageID: parentID),
                      authority: .nativeOwned, packageRelativePath: "SKILL.md", contentDigest: first.tree.digest),
            ]))
        let nativeFixture = try Fixture(document: native)
        defer { nativeFixture.remove() }
        let update = StandaloneSkillUpdateCommand(
            expectedRevisionID: native.revision.id,
            artifactID: childID,
            expectedContentDigest: first.tree.digest,
            prepared: second)
        await #expect(throws: WorkspaceSkillCommandError.unsupportedAuthority) {
            _ = try await nativeFixture.service.updateStandaloneSkill(update, prepared: second)
        }
        #expect(try nativeFixture.store.snapshot()?.document == native)
    }

    @Test func failedContentPublishAndReceiptInsertLeaveTheHeadUnchanged() async throws {
        let prepared = try personalSkill("first")
        let limited = try Fixture(contentLimits: .init(maxTotalBytes: 1))
        defer { limited.remove() }
        let limitedCommand = StandaloneSkillIntakeCommand(
            expectedRevisionID: limited.document.revision.id, displayName: "Limited", prepared: prepared)
        await #expect(throws: PackageTreeError.limitExceeded) {
            _ = try await limited.service.intakeStandaloneSkill(limitedCommand, prepared: prepared)
        }
        #expect(try limited.store.snapshot()?.document == limited.document)

        let receiptFailure = try Fixture()
        defer { receiptFailure.remove() }
        try receiptFailure.sql("CREATE TRIGGER reject_receipt BEFORE INSERT ON command_receipts BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        let command = StandaloneSkillIntakeCommand(
            expectedRevisionID: receiptFailure.document.revision.id, displayName: "Receipt failure", prepared: prepared)
        await #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try await receiptFailure.service.intakeStandaloneSkill(command, prepared: prepared)
        }
        #expect(try receiptFailure.store.snapshot()?.document == receiptFailure.document)
        #expect(try receiptFailure.scalar("SELECT COUNT(*) FROM revisions") == 1)
        #expect(try receiptFailure.scalar("SELECT COUNT(*) FROM command_receipts") == 0)
        #expect(try await receiptFailure.contentStore.read(prepared.tree.digest) == prepared.tree)
        try receiptFailure.sql("DROP TRIGGER reject_receipt")
        let retried = try await receiptFailure.service.intakeStandaloneSkill(command, prepared: prepared)
        #expect(try receiptFailure.store.snapshot()?.document.revision.id == retried.committedRevisionID)
        #expect(try receiptFailure.scalar("SELECT COUNT(*) FROM revisions") == 2)
        #expect(try receiptFailure.scalar("SELECT COUNT(*) FROM command_receipts") == 1)
    }

    @Test func concurrentConnectionsWithOneKeyCommitAndPublishOnceLogically() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepared = try personalSkill("first")
        let command = StandaloneSkillIntakeCommand(
            expectedRevisionID: fixture.document.revision.id,
            idempotencyKey: WorkspaceObjectID(),
            displayName: "Concurrent",
            prepared: prepared)
        let secondStore = try fixture.reopenStore()
        let secondContent = try CentralPackageContentStore(directory: fixture.contentURL)
        let second = WorkspaceApplicationService(store: secondStore, writerID: fixture.writerID, contentStore: secondContent)

        async let left = fixture.service.intakeStandaloneSkill(command, prepared: prepared)
        async let right = second.intakeStandaloneSkill(command, prepared: prepared)
        let receipts = try await [left, right]
        #expect(receipts[0] == receipts[1])
        #expect(try fixture.scalar("SELECT COUNT(*) FROM revisions") == 2)
        #expect(try fixture.store.snapshot()?.document.artifacts.count == 1)
    }

    @Test func cancelledIntakeAndMissingPriorContentCannotAdvanceTheLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try personalSkill("first")
        let command = StandaloneSkillIntakeCommand(expectedRevisionID: fixture.document.revision.id,
            displayName: "Cancelled", prepared: first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.intakeStandaloneSkill(command, prepared: first)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.store.snapshot()?.document == fixture.document)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.contentURL.appending(path: "objects").path).isEmpty)

        let artifactID = ArtifactID()
        let incomplete = try Fixture(document: initialDocument(artifactID: artifactID, content: first, aliases: [], assignments: []))
        defer { incomplete.remove() }
        let next = try personalSkill("second")
        let update = StandaloneSkillUpdateCommand(expectedRevisionID: incomplete.document.revision.id,
            artifactID: artifactID, expectedContentDigest: first.tree.digest, prepared: next)
        await #expect(throws: CentralPackageStoreError.missingContent) {
            try await incomplete.service.updateStandaloneSkill(update, prepared: next)
        }
        #expect(try incomplete.store.snapshot()?.document == incomplete.document)
        #expect(try FileManager.default.contentsOfDirectory(atPath: incomplete.contentURL.appending(path: "objects").path).isEmpty)
    }

    private func personalSkill(_ payload: String) throws -> PreparedStandaloneSkill {
        let tree = try CapturedPackageTree(entries: [
            .init(relativePath: "empty", kind: .directory),
            .init(relativePath: "resources", kind: .directory),
            .init(relativePath: "resources/data.txt", kind: .file(bytes: Data("resource".utf8), executable: false)),
            .init(relativePath: "bin", kind: .directory),
            .init(relativePath: "bin/run", kind: .file(bytes: Data(payload.utf8), executable: true)),
            .init(relativePath: "current", kind: .symbolicLink(target: "bin/run")),
            .init(relativePath: "SKILL.md", kind: .file(bytes: Data("---\nname: reviewed-skill\ndescription: Reviewed skill\n---\nUse it.\n".utf8), executable: false)),
        ])
        return try WorkspaceSkillPreparation.personal(tree: tree)
    }

    private func initialDocument(
        artifactID: ArtifactID,
        content: PreparedStandaloneSkill,
        aliases: [ExternalAlias],
        assignments: [AssignmentContribution]
    ) throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
            workspaceID: WorkspaceObjectID(),
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [.init(
                identity: .init(id: artifactID, kind: .skill, displayName: "Reviewed label", aliases: aliases),
                authority: .centralPersonal,
                declaredName: content.frontmatter.name,
                contentDigest: content.tree.digest)],
            assignments: assignments))
    }

    private struct Fixture {
        let root: URL
        let contentURL: URL
        let writerID: WorkspaceObjectID
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore
        let contentStore: CentralPackageContentStore
        let service: WorkspaceApplicationService

        init(document: PortableWorkspaceDocument? = nil, contentLimits: PackageTreeLimits = .default) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "workspace-skill-command-\(UUID())")
            contentURL = root.appending(path: "content")
            try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            writerID = document?.revision.writerID ?? WorkspaceObjectID()
            self.document = try document ?? WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID)))
            device = DeviceWorkspaceState(workspaceID: self.document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root, workspaceID: self.document.workspaceID, deviceID: device.deviceID)
            contentStore = try CentralPackageContentStore(directory: contentURL, limits: contentLimits)
            try store.initialize(document: self.document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
        }

        func reopenStore() throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        }

        func sql(_ command: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else {
                throw WorkspaceRevisionStoreError.databaseUnavailable
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(database, command, nil, nil, nil) == SQLITE_OK else {
                throw WorkspaceRevisionStoreError.corruptState
            }
        }

        func scalar(_ command: String) throws -> Int32 {
            var database: OpaquePointer?
            guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else {
                throw WorkspaceRevisionStoreError.databaseUnavailable
            }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw WorkspaceRevisionStoreError.corruptState
            }
            return sqlite3_column_int(statement, 0)
        }

        func remove() {
            Self.makeDirectoriesRemovable(root)
            try? FileManager.default.removeItem(at: root)
        }
        private static func makeDirectoriesRemovable(_ url: URL) {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { return }
            _ = chmod(url.path, 0o700)
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                makeDirectoriesRemovable(child)
            }
        }
    }
}

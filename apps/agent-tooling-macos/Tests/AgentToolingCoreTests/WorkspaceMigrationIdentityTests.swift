import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceMigrationIdentityTests {
    let workspace = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test func allocationMatchesIndependentSHA256GoldenVector() throws {
        let entries = try WorkspaceMigrationIdentity.mapping(keys: [.init(domain: .skill, identifier: "docs")], workspaceID: workspace)
        #expect(entries.count == 1)
        #expect(entries.first?.objectID.rawValue.uuidString.lowercased() == "b334f1b4-c5d8-8a9d-8e2a-4714ce10eceb")
    }

    @Test func kindOwnerAndWorkspaceQualifyIdentityAndOrderDoesNot() throws {
        let keys: [LegacyReferenceKey] = [
            .init(domain: .skill, identifier: "docs"), .init(domain: .plugin, identifier: "docs"),
            .init(domain: .mcpServer, identifier: "docs"), .init(domain: .configuration, identifier: "docs"),
            .init(domain: .configuration, identifier: "docs", ownerPolicyID: "company"),
        ]
        let first = try WorkspaceMigrationIdentity.mapping(keys: Set(keys), workspaceID: workspace)
        let second = try WorkspaceMigrationIdentity.mapping(keys: Set(keys.reversed()), workspaceID: workspace)
        #expect(first == second)
        #expect(Set(first.map(\.objectID)).count == keys.count)
        let other = try WorkspaceMigrationIdentity.mapping(keys: Set(keys), workspaceID: WorkspaceObjectID())
        #expect(Set(first.map(\.objectID)).isDisjoint(with: other.map(\.objectID)))
    }

    @Test func previouslyAllocatedIdentitySurvivesMissingRowsAndNewRows() throws {
        let missing = LegacyReferenceKey(domain: .skill, identifier: "temporarily-absent")
        let pinnedID = WorkspaceObjectID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let pinned = WorkspaceMigrationIdentityEntry(legacy: missing, objectID: pinnedID)
        let added = LegacyReferenceKey(domain: .skill, identifier: "new")
        let first = try WorkspaceMigrationIdentity.mapping(keys: [added], workspaceID: workspace, preserving: [pinned])
        #expect(first.contains(pinned))
        #expect(first.count == 2)
        #expect(try WorkspaceMigrationIdentity.mapping(keys: [missing, added], workspaceID: workspace, preserving: first) == first)
    }

    @Test func unicodeEqualityAndFieldBoundariesProduceConsistentIdentities() throws {
        let composed = LegacyReferenceKey(domain: .configuration, identifier: "caf\u{00e9}", ownerPolicyID: "company")
        let decomposed = LegacyReferenceKey(domain: .configuration, identifier: "cafe\u{0301}", ownerPolicyID: "company")
        #expect(composed == decomposed)
        let first = try WorkspaceMigrationIdentity.mapping(keys: [composed], workspaceID: workspace)
        let second = try WorkspaceMigrationIdentity.mapping(keys: [decomposed], workspaceID: workspace)
        #expect(first.first?.objectID == second.first?.objectID)
        let fields: Set<LegacyReferenceKey> = [
            .init(domain: .configuration, identifier: "a:b", ownerPolicyID: "c"),
            .init(domain: .configuration, identifier: "a", ownerPolicyID: "b:c"),
        ]
        #expect(Set(try WorkspaceMigrationIdentity.mapping(keys: fields, workspaceID: workspace).map(\.objectID)).count == 2)
    }

    @Test func catalogUUIDIsRetainedUnlessAlreadyReservedForAnotherEntity() throws {
        let uuid = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let catalog = LegacyReferenceKey(domain: .catalogSource, identifier: uuid.uuidString.lowercased())
        let original = try WorkspaceMigrationIdentity.mapping(keys: [catalog], workspaceID: workspace)
        #expect(original.first?.objectID.rawValue == uuid)

        let existing = WorkspaceMigrationIdentityEntry(
            legacy: .init(domain: .skill, identifier: "prior"), objectID: WorkspaceObjectID(uuid))
        let reallocated = try WorkspaceMigrationIdentity.mapping(keys: [catalog], workspaceID: workspace, preserving: [existing])
        #expect(reallocated.first(where: { $0.legacy == catalog })?.objectID.rawValue != uuid)
        #expect(reallocated.contains(existing))
        #expect(try WorkspaceMigrationIdentity.mapping(keys: [catalog], workspaceID: workspace, preserving: reallocated) == reallocated)
    }

    @Test func invalidPersistedMappingsFailRatherThanReplacingAnIdentity() throws {
        let key = LegacyReferenceKey(domain: .skill, identifier: "one")
        let entry = WorkspaceMigrationIdentityEntry(legacy: key, objectID: WorkspaceObjectID())
        #expect(throws: WorkspaceMigrationIdentityError.duplicateKey) {
            _ = try WorkspaceMigrationIdentity.mapping(keys: [], workspaceID: workspace, preserving: [entry, entry])
        }
        let collision = WorkspaceMigrationIdentityEntry(legacy: .init(domain: .plugin, identifier: "two"), objectID: entry.objectID)
        #expect(throws: WorkspaceMigrationIdentityError.duplicateIdentity) {
            _ = try WorkspaceMigrationIdentity.mapping(keys: [], workspaceID: workspace, preserving: [entry, collision])
        }
        #expect(throws: WorkspaceMigrationIdentityError.invalidIdentity) {
            _ = try WorkspaceMigrationIdentity.mapping(
                keys: [.init(domain: .skill, identifier: "one", ownerPolicyID: "company")], workspaceID: workspace)
        }
    }
}

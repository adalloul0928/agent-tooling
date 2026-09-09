import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceConfigurationProjectBindingTests {
    private let workspaceID = WorkspaceObjectID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000a01")!)

    @Test func rejectsBindingForAbsentConfiguration() throws {
        let stale = LegacyReferenceKey(domain: .configuration, identifier: "absent")
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: .init(profiles: [profile("current")], activeProfileID: "current"),
            workspaceID: workspaceID,
            artifactBindings: [:],
            projectBindings: [stale: ArtifactID()]
        )

        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .invalidPath && $0.reference == stale })
        #expect(preview.state.configurations.allSatisfy { $0.logicalProjectID == nil })
    }

    @Test func rejectsBindingForLiveNonProjectConfiguration() throws {
        let user = LegacyReferenceKey(domain: .configuration, identifier: "user")
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: .init(profiles: [profile("user")], activeProfileID: "user"),
            workspaceID: workspaceID,
            artifactBindings: [:],
            projectBindings: [user: ArtifactID()]
        )

        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .invalidPath && $0.reference == user })
        #expect(preview.state.configurations.first?.logicalProjectID == nil)
    }

    @Test func rejectsBindingWithWrongManagedPolicyNamespace() throws {
        let wrongOwner = LegacyReferenceKey(
            domain: .configuration, identifier: "shared", ownerPolicyID: "other-policy")
        let snapshot = WorkspaceSnapshot(
            activeProfileID: "",
            managedPolicies: [
                .init(
                    id: "company",
                    name: "Company",
                    sourcePath: "/private/company-policy.json",
                    profiles: [profile("shared", scope: .project, root: "/work/company")]
                ),
            ]
        )
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            artifactBindings: [:],
            projectBindings: [wrongOwner: ArtifactID()]
        )

        #expect(!preview.canMigrateConfigurations)
        #expect(preview.blockers.contains { $0.kind == .invalidPath && $0.reference == wrongOwner })
        let managed = try #require(preview.state.configurations.first)
        #expect(managed.logicalProjectID == nil)
    }

    @Test func sameLegacyIDInPersonalAndPolicyNamespacesCanShareOneProject() throws {
        let projectID = ArtifactID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000a02")!)
        let personal = LegacyReferenceKey(domain: .configuration, identifier: "shared")
        let managed = LegacyReferenceKey(
            domain: .configuration, identifier: "shared", ownerPolicyID: "company")
        let snapshot = WorkspaceSnapshot(
            profiles: [profile("shared", scope: .project, root: "/work/shared")],
            // Active-profile ambiguity is validated separately. This fixture
            // isolates policy-owner namespaces in project bindings.
            activeProfileID: "",
            managedPolicies: [
                .init(
                    id: "company",
                    name: "Company",
                    sourcePath: "/private/company-policy.json",
                    profiles: [profile("shared", scope: .localProject, root: "/work/shared")]
                ),
            ]
        )
        let preview = try WorkspaceConfigurationMigration.preview(
            snapshot: snapshot,
            workspaceID: workspaceID,
            artifactBindings: [:],
            projectBindings: [personal: projectID, managed: projectID]
        )

        #expect(preview.canMigrateConfigurations, "configuration blockers: \(preview.blockers)")
        #expect(preview.state.configurations.count == 2)
        #expect(preview.state.configurations.allSatisfy { $0.logicalProjectID == projectID })
        #expect(Set(preview.state.identityMap.filter {
            $0.legacy.domain == .configuration && $0.legacy.identifier == "shared"
        }.map(\.legacy)) == Set([personal, managed]))
    }

    private func profile(
        _ id: String,
        scope: ToolingScope = .user,
        root: String? = nil
    ) -> ToolingProfile {
        .init(
            id: id,
            name: id,
            summary: "",
            scope: scope,
            projectRoot: root,
            checks: [],
            enabledPlugins: [],
            requiredMCPs: []
        )
    }
}

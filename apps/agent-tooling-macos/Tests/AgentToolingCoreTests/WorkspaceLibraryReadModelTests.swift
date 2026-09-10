import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceLibraryReadModelTests {
    @Test func rootsKeepNativeChildrenIncludedAndPreserveOwnershipProvenance() throws {
        let fixture = try Fixture()
        let model = try WorkspaceLibraryReadModel(snapshot: fixture.snapshot)

        #expect(model.rows.map(\.artifactID) == [fixture.nativeRootID, fixture.personalID, fixture.trackedID, fixture.upstreamID])
        let native = try #require(model.rows.first { $0.artifactID == fixture.nativeRootID })
        #expect(native.ownership == .nativeOwned)
        #expect(native.nativeRoutes == [.init(client: .claude, externalPluginID: "marketplace@vendor")])
        #expect(native.childCount == 1)
        #expect(native.includedChildren.first?.artifactID == fixture.nativeChildID)
        #expect(native.includedChildren.first?.parentPluginLabel == "Native Plugin")
        #expect(native.includedChildren.first?.requestedAssignments.isEmpty == true)
        #expect(native.isAssignable)

        let upstream = try #require(model.rows.first { $0.artifactID == fixture.upstreamID })
        #expect(upstream.ownership == .centralUpstream)
        #expect(upstream.sourceLabel == "github.com/acme/tooling.git")
        #expect(upstream.observedDescription == nil)

        let tracked = try #require(model.rows.first { $0.artifactID == fixture.trackedID })
        #expect(!tracked.isAssignable)
        #expect(tracked.assignableReasons.isEmpty)
        #expect(tracked.assignmentExplanation == "Tracked in this library. Choose how to manage it before assigning.")
    }

    @Test func theLibrarySizeCountsToolsCarriedInsidePluginsNotJustTheRowsAListCanShow() throws {
        let fixture = try Fixture()
        let model = try WorkspaceLibraryReadModel(snapshot: fixture.snapshot)

        // Four entries, one of which carries a skill of its own. Reporting
        // `rows.count` would tell the owner of five tools that they have four.
        #expect(model.rows.count == 4)
        #expect(model.nestedToolCount == 1)
        #expect(model.toolCount == 5)
        // Every tool is counted once and nothing else is: the preset and the
        // project in this document are not tools and must not inflate it.
        let tools = fixture.document.artifacts.filter {
            [.package, .skill, .mcpServer, .nativePlugin].contains($0.identity.kind)
        }
        #expect(model.toolCount == tools.count)
        #expect(fixture.document.artifacts.count == tools.count + 2)
    }

    @Test func requestedAssignmentsRetainForeignDeviceIntentWithoutClaimingInstallation() throws {
        let fixture = try Fixture()
        let model = try WorkspaceLibraryReadModel(snapshot: fixture.snapshot)
        let personal = try #require(model.rows.first { $0.artifactID == fixture.personalID })

        #expect(personal.requestedAssignments.count == 2)
        #expect(personal.requestedAssignments.map(\.deviceScope) == [.allEnrolledDevices, .otherDevices])
        #expect(personal.requestedAssignments.map(\.desiredEnabled) == [nil, false])
        #expect(personal.requestedAssignments.map(\.reason) == [.manual, .projectDeclaration(projectID: fixture.projectID)])
        #expect(personal.observedDescription == nil)
    }

    @Test func searchUsesCachedLibraryFieldsAndPresetsProjectsRemainSeparate() throws {
        let fixture = try Fixture()
        let model = try WorkspaceLibraryReadModel(snapshot: fixture.snapshot)

        #expect(model.filteredRows(matching: "UPSTREAM").map(\.artifactID) == [fixture.upstreamID])
        #expect(model.filteredRows(matching: "native child").map(\.artifactID) == [fixture.nativeRootID])
        #expect(model.filteredRows(matching: "marketplace@vendor").map(\.artifactID) == [fixture.nativeRootID])
        #expect(model.presets == [.init(id: fixture.presetID, name: "Starter", revision: 2, memberArtifactIDs: [fixture.personalID])])
        #expect(model.projects == [.init(id: fixture.projectID, name: "Project A", repositoryHints: ["https://github.com/acme/project"])])
    }

    @Test func renamingKeepsStableArtifactIdentityAndDeterministicTieOrder() throws {
        let fixture = try Fixture()
        let first = try WorkspaceLibraryReadModel(snapshot: fixture.snapshot)
        var renamed = fixture.document
        let index = try #require(renamed.artifacts.firstIndex { $0.identity.id == fixture.personalID })
        renamed.artifacts[index].identity.displayName = "A personal skill"
        let second = try WorkspaceLibraryReadModel(snapshot: .init(document: renamed, device: fixture.device))

        #expect(first.rows.first { $0.artifactID == fixture.personalID }?.id == fixture.personalID)
        #expect(second.rows.first?.artifactID == fixture.personalID)
        #expect(second.rows.map(\.artifactID).contains(fixture.personalID))
    }


    /// `declaredName` is the only key that joins a row to a device
    /// observation, on both shapes the model hands out: a root row and a
    /// child folded into one. An artifact that never declared a name joins
    /// nothing, so it stays `nil` rather than falling back to a guess.
    @Test func declaredNameCarriesFromTheArtifactToBothRowShapes() throws {
        let workspaceID = WorkspaceObjectID()
        let writerID = WorkspaceObjectID()
        let pluginID = ArtifactID()
        let childID = ArtifactID()
        let namedID = ArtifactID()
        let unnamedID = ArtifactID()
        let document = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: workspaceID,
                revision: .init(writerID: writerID),
                artifacts: [
                    .init(
                        identity: .init(id: pluginID, kind: .nativePlugin, displayName: "Plugin"),
                        authority: .nativeOwned, declaredName: "vendor-plugin"),
                    .init(
                        identity: .init(
                            id: childID, kind: .skill, displayName: "Child Skill", parentPackageID: pluginID),
                        authority: .nativeOwned, declaredName: "child-skill", packageRelativePath: "skills/child"),
                    .init(
                        identity: .init(id: namedID, kind: .skill, displayName: "Named Skill"),
                        authority: .centralPersonal, declaredName: "named-skill"),
                    .init(
                        identity: .init(id: unnamedID, kind: .skill, displayName: "Unnamed Skill"),
                        authority: .centralPersonal),
                ]))
        let device = DeviceWorkspaceState(workspaceID: workspaceID)
        let model = try WorkspaceLibraryReadModel(snapshot: .init(document: document, device: device))

        let plugin = try #require(model.rows.first { $0.artifactID == pluginID })
        #expect(plugin.declaredName == "vendor-plugin")
        let child = try #require(plugin.includedChildren.first { $0.artifactID == childID })
        #expect(child.declaredName == "child-skill")

        let named = try #require(model.rows.first { $0.artifactID == namedID })
        #expect(named.declaredName == "named-skill")
        let unnamed = try #require(model.rows.first { $0.artifactID == unnamedID })
        #expect(unnamed.declaredName == nil)
    }

    @Test func buildsAParentIndexForDenseStandaloneRoots() throws {
        let workspaceID = WorkspaceObjectID()
        let writerID = WorkspaceObjectID()
        let artifacts = (0..<5_000).map { offset in
            ArtifactRecord(
                identity: .init(id: ArtifactID(), kind: .skill, displayName: "Skill \(offset)"),
                authority: .centralPersonal
            )
        }
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID,
            revision: .init(writerID: writerID),
            artifacts: artifacts
        ))
        let device = DeviceWorkspaceState(workspaceID: workspaceID)
        let model = try WorkspaceLibraryReadModel(snapshot: .init(document: document, device: device))

        #expect(model.rows.count == 5_000)
        #expect(model.rows.allSatisfy { $0.childCount == 0 })
    }

    private struct Fixture {
        let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let deviceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let otherDeviceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let writerID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let sourceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        let subscriptionID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
        let nativeRootID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let nativeChildID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let personalID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let upstreamID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        let trackedID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000014")!)
        let presetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000015")!)
        let projectID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000016")!)
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState

        var snapshot: WorkspaceApplicationSnapshot { .init(document: document, device: device) }

        init() throws {
            let digest = ContentDigest(value: String(repeating: "a", count: 64))
            document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID,
                revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: nativeRootID, kind: .nativePlugin, displayName: "Native Plugin"), authority: .nativeOwned,
                          nativeRoutes: [.init(client: .claude, externalPluginID: "marketplace@vendor")]),
                    .init(identity: .init(id: nativeChildID, kind: .skill, displayName: "Native Child", parentPackageID: nativeRootID),
                          authority: .nativeOwned, packageRelativePath: "skills/child"),
                    .init(identity: .init(id: personalID, kind: .skill, displayName: "Personal Skill"), authority: .centralPersonal),
                    .init(identity: .init(id: upstreamID, kind: .skill, displayName: "Upstream Skill"), authority: .centralUpstream(subscriptionID: subscriptionID)),
                    .init(identity: .init(id: trackedID, kind: .mcpServer, displayName: "Tracked Server"), authority: .trackedOnly),
                    .init(identity: .init(id: presetID, kind: .preset, displayName: "Starter"), authority: .centralPersonal),
                    .init(identity: .init(id: projectID, kind: .logicalProject, displayName: "Project A"), authority: .centralPersonal)
                ],
                sources: [.init(id: sourceID, role: .publisherRepository, repositoryURL: "https://github.com/acme/tooling.git", requestedRef: "main", packageRelativePaths: ["."])],
                subscriptions: [.init(id: subscriptionID, artifactID: upstreamID, sourceID: sourceID,
                    lock: .init(publisherID: "acme", sourceRootID: sourceID, requestedRef: "main",
                                approvedRevision: .init(kind: .semanticVersion, value: "1.0.0"), approvedContent: digest, packageRelativePath: "."))],
                logicalProjects: [.init(id: projectID, name: "Project A", repositoryHints: ["https://github.com/acme/project"])],
                assignments: [
                    .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!), artifactID: personalID,
                          destination: .init(surface: .claudeCode, scope: .user), reason: .manual),
                    .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!), artifactID: personalID,
                          destination: .init(surface: .codexCLI, scope: .project, logicalProjectID: projectID, deviceIDs: [otherDeviceID]),
                          reason: .projectDeclaration(projectID: projectID), desiredEnabled: false)
                ],
                presets: [.init(id: presetID, name: "Starter", revision: 2, memberArtifactIDs: [personalID])]
            ))
            device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
        }
    }
}

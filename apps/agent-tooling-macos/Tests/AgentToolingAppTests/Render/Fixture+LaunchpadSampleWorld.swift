import AgentToolingCore
import AgentToolingTestSupport
import Foundation

@testable import AgentToolingApp

/// Synthetic workspaces after each setup step, built through Core commands.
/// Client commands are stubbed; observations supply their expected results.
enum LaunchpadSampleSnapshot: String, CaseIterable, Sendable {
    /// Juniper's read has finished and the library exists: Your library, as
    /// read.
    case afterRead
    /// Release Notes and Frontend Design (Claude Code's newer copy) are made
    /// yours, and Supabase is added from Claude Code's catalog.
    case afterLibrary
    /// Release Notes and Frontend Design are put in Codex and Claude Code, and
    /// Supabase in Claude Code, all on every Mac.
    case afterPlace
    /// Agent Tooling's own connection is recorded for Codex and Claude Code,
    /// on this Mac only. The review lists 5 steps and 4 run: Frontend Design
    /// in Codex is left alone.
    case afterAsk
    /// The 4 steps ran: Release Notes was copied into Codex for real, and the
    /// re-check that follows an install found Supabase in Claude Code and
    /// Agent Tooling's connection in Codex and Claude Code.
    case afterInstall
    /// Cedar joined the library Juniper shares, at You joined.
    case cedarJoined

    /// The step the walk is on at this point.
    var cursor: LaunchpadStep {
        switch self {
        case .afterRead: .found
        case .afterLibrary: .place
        case .afterPlace: .ask
        case .afterAsk: .ask
        case .afterInstall: .assistant
        case .cedarJoined: .arrivals
        }
    }

    /// The path the walk took to get here.
    var path: LaunchpadPath { self == .cedarJoined ? .join : .startHere }
}

/// One snapshot: the workspace, what the walk decided and did to get there,
/// and the other Mac a join needs.
@MainActor
struct LaunchpadSample {
    let snapshot: LaunchpadSampleSnapshot
    let workspace: WorkspaceLaunch.Workspace
    let decisions: LaunchpadLibraryDecisions
    let outcomes: LaunchpadOutcomes
    /// Juniper, whose library Cedar joined: a fixture of its own, holding the
    /// shared repository. Nil for Juniper's own snapshots.
    let peer: LaunchpadFixture?

    /// The library's standalone item declared as `declaredName`.
    func artifact(_ declaredName: String) -> ArtifactRecord? {
        workspace.library.state?.snapshot.document.artifacts.first {
            $0.declaredName == declaredName && $0.identity.parentPackageID == nil
        }
    }

    /// Removes the other Mac, when there is one. The fixture that made the
    /// sample removes its own world.
    func remove() { peer?.remove() }
}

extension LaunchpadFixture {
    /// The helper the sample world registers: a runnable file inside a copy
    /// of the app in the fixture's own Applications folder, so its path has
    /// the spaces the real one has.
    var helperPath: String {
        world.home.root
            .appending(path: "Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp")
            .path(percentEncoded: false)
    }

    /// Discover's picks on Start your library, as Claude Code's and Codex's
    /// catalogs list them. Supabase is the one the walk adds.
    nonisolated static var catalogListings: [MarketplacePackage] {
        [
            supabaseListing,
            listing(
                "vercel@claude-plugins-official", name: "Vercel", publisher: "Vercel",
                summary: "Deploy and inspect Vercel projects.", client: .claude),
            listing(
                "github@openai-curated", name: "GitHub for Codex", publisher: "GitHub",
                summary: "GitHub issues and pull requests in Codex.", client: .codex),
        ]
    }

    /// The Supabase listing in Claude Code's catalog.
    nonisolated static var supabaseListing: MarketplacePackage {
        listing(
            "supabase@claude-plugins-official", name: "Supabase", publisher: "Supabase",
            summary: "Supabase database, auth and storage from Claude Code.", client: .claude)
    }

    /// A listing shaped as each app's catalog parser leaves one, so
    /// `NativeCatalogPackageIdentity` recognizes it.
    private nonisolated static func listing(
        _ pluginID: String, name: String, publisher: String, summary: String, client: ClientKind
    ) -> MarketplacePackage {
        let install: [String] =
            client == .claude ? ["plugin", "install", pluginID, "--scope", "user"] : ["plugin", "install", pluginID]
        return MarketplacePackage(
            id: "\(client == .claude ? "claude" : "codex"):\(pluginID)", name: name, publisher: publisher,
            summary: summary, sourceName: "\(client.rawValue)’s catalog", components: [.plugin],
            supportedClients: [client], trustSummary: "Listed by \(client.rawValue)’s catalog; review before installing",
            location: "https://example.com/\(pluginID)",
            nativeInstalls: [
                NativeInstall(
                    client: client, executable: ClientExecutableLocator.executableName(for: client), arguments: install,
                    removalArguments: ["plugin", "uninstall", pluginID], scope: .user,
                    detail: "Installs through \(client.rawValue)’s own plugin manager.")
            ])
    }

    /// The sample world at `snapshot`. Juniper's snapshots need a Juniper
    /// fixture, and Cedar's a Cedar one. Each call builds the library afresh
    /// in this fixture's support folder, so a fixture takes one.
    func sample(_ snapshot: LaunchpadSampleSnapshot) async throws -> LaunchpadSample {
        switch snapshot {
        case .afterRead: return try await afterRead()
        case .afterLibrary: return try await afterLibrary(from: afterRead())
        case .afterPlace: return try await afterPlace(from: afterLibrary(from: afterRead()))
        case .afterAsk: return try await afterAsk(from: afterPlace(from: afterLibrary(from: afterRead())))
        case .afterInstall:
            return try await afterInstall(from: afterAsk(from: afterPlace(from: afterLibrary(from: afterRead()))))
        case .cedarJoined: return try await cedarJoined()
        }
    }

    /// A first run's stage at `snapshot`, holding what the walk decided and
    /// did, over the snapshot's workspace.
    func flow(at snapshot: LaunchpadSampleSnapshot) async throws -> (flow: LaunchpadFlow, sample: LaunchpadSample) {
        let sample = try await sample(snapshot)
        let flow = flow(.continueFirstRun(snapshot.cursor), workspace: sample.workspace)
        if snapshot.path == .startHere { flow.seedOverride = seed }
        flow.decisions = sample.decisions
        flow.outcomes = sample.outcomes
        return (flow, sample)
    }

    // MARK: Juniper

    private func afterRead() async throws -> LaunchpadSample {
        precondition(world.world != .cedar, "Juniper's snapshots need a Juniper fixture")
        let record = SetupProgressRecord.started(path: .startHere, cursor: .found, now: ClientHomeFixture.now)
        let store = environment.progressStore
        let workspace = try await WorkspaceLaunch.create(
            observations: orderedObservations, preferences: seed.preferences, supportRoot: support, homeRoot: home,
            beforeRecord: { try store($0).save(record) }, services: environment.sessions)
        await workspace.library.refresh()
        // The sign-in reads land, then the stage audit runs, as on the stage.
        await workspace.accounts.seed(Self.orderedSignIns(for: world.world))
        await workspace.setup.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false)
        let manifest = FirstReadManifest.build(chosen: world.found, homeURL: home, includeProjectHistory: true)
        var outcomes = LaunchpadOutcomes()
        outcomes.read = .init(
            looked: orderedObservations.compactMap { observation in
                observation.surface.client.map { .init(client: $0, version: ClientVersionText.number(in: observation.version)) }
            },
            notFound: ClientKind.allCases.filter { !world.found.contains($0) }, places: manifest.placeCount,
            commands: manifest.commandCount)
        return LaunchpadSample(
            snapshot: .afterRead, workspace: workspace, decisions: LaunchpadLibraryDecisions(), outcomes: outcomes, peer: nil)
    }

    private func afterLibrary(from read: LaunchpadSample) async throws -> LaunchpadSample {
        let workspace = read.workspace
        var decisions = read.decisions
        // Release Notes has one copy; Frontend Design's two differ, and
        // Claude Code's newer one is brought in.
        for (folder, copyFrom) in [(".claude/skills/release-notes", nil), (".claude/skills/frontend-design", ClientKind.claude)] {
            let prepared = try await WorkspaceSkillPreparation.capturePersonal(
                directory: home.appending(path: folder, directoryHint: .isDirectory))
            let artifact = try trackedSkill(prepared.frontmatter.name, in: workspace)
            _ = try await workspace.service.adoptTrackedSkill(
                .init(expectedRevisionID: try head(of: workspace), artifactID: artifact.identity.id, prepared: prepared),
                prepared: prepared)
            decisions.adopted.append(.init(artifactID: artifact.identity.id, name: artifact.identity.displayName, copyFrom: copyFrom))
        }
        let supabase = try NativePackageAdoptionCommand(
            expectedRevisionID: try head(of: workspace), package: Self.supabaseListing, client: .claude)
        _ = try await workspace.service.adoptNativePackage(supabase)
        await workspace.library.refresh()
        decisions.added.append(.init(artifactID: supabase.artifactID, name: supabase.displayName, source: .catalog(.claude)))
        workspace.setupProgress.move(to: .library, now: ClientHomeFixture.now)
        workspace.setupProgress.move(to: .place, now: ClientHomeFixture.now)
        var outcomes = read.outcomes
        outcomes.addedPluginsAwaitingCheck = [supabase.displayName]
        return LaunchpadSample(snapshot: .afterLibrary, workspace: workspace, decisions: decisions, outcomes: outcomes, peer: nil)
    }

    private func afterPlace(from library: LaunchpadSample) async throws -> LaunchpadSample {
        let workspace = library.workspace
        var decisions = library.decisions
        let releaseNotes = try artifact(id: decisions.adopted[0].artifactID, in: workspace)
        let frontendDesign = try artifact(id: decisions.adopted[1].artifactID, in: workspace)
        let supabase = try artifact(id: decisions.added[0].artifactID, in: workspace)
        // Every Mac: a destination naming no device, so a Mac that joins
        // later takes it too.
        let placements: [(ArtifactRecord, [ClientKind])] = [
            (releaseNotes, [.codex, .claude]), (frontendDesign, [.codex, .claude]), (supabase, [.claude]),
        ]
        let additions = placements.flatMap { artifact, apps in
            apps.map { app in
                AssignmentContribution(
                    artifactID: artifact.identity.id, destination: .init(surface: app.defaultSurface, scope: .user),
                    reason: .manual)
            }
        }
        _ = try await workspace.service.applyAssignmentBatch(
            .init(expectedRevisionID: try head(of: workspace), additions: additions))
        await workspace.library.refresh()
        decisions.placed = placements.map { artifact, apps in
            .init(artifactID: artifact.identity.id, name: artifact.identity.displayName, apps: apps, scope: .everyMac)
        }
        decisions.contributionIDs = additions.map(\.id)
        workspace.setupProgress.recordEvidence { $0.placedContributionIDs = additions.map(\.id) }
        workspace.setupProgress.move(to: .ask, now: ClientHomeFixture.now)
        return LaunchpadSample(
            snapshot: .afterPlace, workspace: workspace, decisions: decisions, outcomes: library.outcomes, peer: nil)
    }

    private func afterAsk(from place: LaunchpadSample) async throws -> LaunchpadSample {
        let workspace = place.workspace
        var decisions = place.decisions
        try plantHelper()
        // The connection is a command bound to each Mac: the definition every
        // Mac shares says only that, and this Mac's binding holds the path.
        var draft = MCPDraft()
        draft.name = AgentToolingConnection.displayName
        draft.endpoint = "'\(helperPath)'"
        draft.transport = .stdio
        draft.authentication = "None"
        let intake = try ManagedMCPServerIntakeCommand(expectedRevisionID: try head(of: workspace), draft: draft)
        _ = try await workspace.service.intakeManagedMCPServer(intake)
        let apps: [ClientKind] = [.codex, .claude]
        let thisMac = workspace.store.deviceID
        let additions = apps.map { app in
            AssignmentContribution(
                artifactID: intake.artifactID,
                destination: .init(surface: app.defaultSurface, scope: .user, deviceIDs: [thisMac]), reason: .manual)
        }
        _ = try await workspace.service.applyAssignmentBatch(
            .init(expectedRevisionID: try head(of: workspace), additions: additions))
        await workspace.library.refresh()
        decisions.helperArtifactID = intake.artifactID
        decisions.helperApps = apps
        var outcomes = place.outcomes
        outcomes.helperApps = apps
        return LaunchpadSample(snapshot: .afterAsk, workspace: workspace, decisions: decisions, outcomes: outcomes, peer: nil)
    }

    private func afterInstall(from ask: LaunchpadSample) async throws -> LaunchpadSample {
        let workspace = ask.workspace
        let deployment = workspace.deployment
        await deployment.prepare()
        guard let plan = deployment.plan else { throw WorkspaceRevisionStoreError.corruptState }
        let leftAlone = deployment.heldBack(in: plan).map(WorkspaceDeploymentSession.installKey)
        // The content step runs for real: the reviewed copy into Codex's
        // folder, with its receipt. The plugin and connection steps run each
        // app's own tool, so their result is what the re-check after an
        // install reads: the files and listings those tools leave.
        let releaseNotes = try artifact(id: ask.decisions.adopted[0].artifactID, in: workspace)
        await deployment.apply(only: [releaseNotes.identity.id])
        let finishedAt = ClientHomeFixture.now.addingTimeInterval(Self.installMinutes * 60)
        observer.answer(with: try await installedObservations(at: finishedAt))
        await workspace.device.refresh(only: [.codex, .claude])
        await deployment.prepare()
        await workspace.setup.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false)
        workspace.setupProgress.move(to: .assistant, now: finishedAt)
        var outcomes = ask.outcomes
        outcomes.install = DeploymentOutcome(
            installed: [.codex, .claude], leftAlone: leftAlone, succeededSteps: plan.items.count - leftAlone.count,
            finishedAt: finishedAt)
        return LaunchpadSample(
            snapshot: .afterInstall, workspace: workspace, decisions: ask.decisions, outcomes: outcomes, peer: nil)
    }

    /// The install finishes at 9:52, eleven minutes into the walk.
    nonisolated static let installMinutes: Double = 11

    /// What Codex and Claude Code report after the install: Supabase among
    /// Claude Code's plugins, and Agent Tooling's connection in both, read by
    /// the bundled adapters from the files and listings each app's own
    /// install leaves. Gemini CLI keeps its last check.
    private func installedObservations(at checkedAt: Date) async throws -> [TargetObservation] {
        let homePath = ProjectPath.canonical(home)
        let supabase = "supabase@claude-plugins-official"
        let supabaseFolder = ".claude/plugins/cache/claude-plugins-official/supabase/1.0.0"
        try world.home.plant("\(supabaseFolder)/.claude-plugin/plugin.json", #"{"name":"supabase","version":"1.0.0"}"# + "\n")
        try world.home.plant(
            ".claude/settings.json",
            #"{"enabledPlugins":{"github@claude-plugins-official":true,"sentry@claude-plugins-official":true,"\#(supabase)":true}}"#
                + "\n")
        // The path as a JSON string, which is also how TOML spells it: with
        // its slashes as they are, since TOML has no `\/` escape.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let helper = String(decoding: try encoder.encode(helperPath), as: UTF8.self)
        try world.home.plant(
            ".claude.json",
            #"{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"},"#
                + #""playwright":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]},"#
                + #""agent-tooling":{"type":"stdio","command":\#(helper),"args":[]}}}"# + "\n")
        try world.home.plant(
            ".codex/config.toml",
            "[mcp_servers.playwright]\ncommand = \"npx\"\nargs = [\"@playwright/mcp@latest\"]\n\n"
                + "[mcp_servers.agent-tooling]\ncommand = \(helper)\nargs = []\n")

        var replies = world.replies
        let claude = ClientExecutableLocator.executableName(for: .claude)
        let codex = ClientExecutableLocator.executableName(for: .codex)
        let listed = try appending(
            #"{"id":"\#(supabase)","version":"1.0.0","scope":"user","enabled":true,"installPath":"\#(homePath)/\#(supabaseFolder)"}"#,
            to: world.answers(for: .claude)[["plugin", "list", "--json"]] ?? "[]")
        replies[claude]?[["plugin", "list", "--json"]] = .standardOutput(listed + "\n")
        let servers = try appending(
            #"{"name":"agent-tooling","enabled":true,"transport":{"type":"stdio","command":\#(helper),"args":[]},"auth_status":"unsupported"}"#,
            to: world.answers(for: .codex)[["mcp", "list", "--json"]] ?? "[]")
        replies[codex]?[["mcp", "list", "--json"]] = .standardOutput(servers + "\n")
        let runner = ScriptedCommandRunner(
            byTool: replies,
            missingTools: Set(
                ClientKind.allCases.filter { !world.found.contains($0) }.map(ClientExecutableLocator.executableName(for:))))
        let rechecked = await world.registry.scanAll(homeURL: home, runner: runner, clients: [.codex, .claude])
        let surfaces = Set(rechecked.map(\.surface))
        let kept = orderedObservations.filter { !surfaces.contains($0.surface) }
        let fresh = rechecked.map { observation in
            var observation = observation
            observation.lastScannedAt = checkedAt
            return observation
        }
        return (kept + fresh).sorted { $0.surface.displayName < $1.surface.displayName }
    }

    /// `object` added to the end of the JSON array `array`.
    private func appending(_ object: String, to array: String) throws -> String {
        var items = try JSONSerialization.jsonObject(with: Data(array.utf8)) as? [Any] ?? []
        items.append(try JSONSerialization.jsonObject(with: Data(object.utf8)))
        let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func plantHelper() throws {
        try write(URL(filePath: helperPath), "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)
    }

    // MARK: Cedar

    /// Juniper publishes its library, as it stood after Let your apps ask, to
    /// a repository of its own; Cedar joins it. The git calls run for real;
    /// every app's command is answered from the sample world's script, and
    /// Cedar reads only its own home.
    private func cedarJoined() async throws -> LaunchpadSample {
        precondition(world.world == .cedar, "Cedar's snapshot needs a Cedar fixture")
        let juniper = try await PublishedJuniper()
        do {
            // The content Juniper shares lands where Cedar's sessions read it:
            // the joined workspace's own folder.
            let contentDirectory = support.appending(
                path: "workspaces-v1/\(juniper.workspaceID.rawValue.uuidString.lowercased())/content",
                directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: contentDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let joined = try await WorkspaceJoin.join(
                remote: juniper.remote.path(percentEncoded: false),
                checkout: support.appending(path: "sync-checkout", directoryHint: .isDirectory), containerRoot: support,
                homeURL: home, deviceName: "Cedar", runner: JoinRunner(tools: world.scriptedRunner(), homeURL: home),
                registry: world.registry, clients: world.found,
                contentStore: try CentralPackageContentStore(directory: contentDirectory),
                locator: try WorkspaceLocator(root: support))
            let container = joined.store.databaseURL.deletingLastPathComponent()
            try WorkspaceSyncEnrollmentStore(containerRoot: container).write(joined.enrollment)
            try environment.progressStore(container)
                .save(SetupProgressRecord.started(path: .join, cursor: .arrivals, now: ClientHomeFixture.now))
            let workspace = WorkspaceLaunch.sessions(
                store: joined.store, homeRoot: home, isFirstRun: false, services: environment.sessions)
            await workspace.library.refresh()
            await workspace.accounts.seed(Self.orderedSignIns(for: .cedar))
            await workspace.setup.audit(scansIfUnchecked: false, asksLoginShell: false, readsAccounts: false)
            return LaunchpadSample(
                snapshot: .cedarJoined, workspace: workspace, decisions: LaunchpadLibraryDecisions(),
                outcomes: LaunchpadOutcomes(), peer: juniper.fixture)
        } catch {
            juniper.fixture.remove()
            throw error
        }
    }

    /// The sample world's sign-ins in provider order.
    private static func orderedSignIns(for world: ClientHomeFixture.World) -> [AccountObservation] {
        let signIns = signIns(for: world)
        return AccountProvider.allCases.compactMap { signIns[$0] }
    }

    // MARK: Reading the library

    /// The revision the library is at.
    func head(of workspace: WorkspaceLaunch.Workspace) throws -> WorkspaceObjectID {
        guard let head = try workspace.store.snapshot()?.document.revision.id else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        return head
    }

    /// The standalone skill the first read tracked as `declaredName`.
    private func trackedSkill(_ declaredName: String, in workspace: WorkspaceLaunch.Workspace) throws -> ArtifactRecord {
        guard
            let artifact = try workspace.store.snapshot()?.document.artifacts.first(where: {
                $0.identity.kind == .skill && $0.authority == .trackedOnly && $0.declaredName == declaredName
                    && $0.identity.parentPackageID == nil
            })
        else { throw WorkspaceRevisionStoreError.missingArtifact }
        return artifact
    }

    private func artifact(id: ArtifactID, in workspace: WorkspaceLaunch.Workspace) throws -> ArtifactRecord {
        guard let artifact = try workspace.store.snapshot()?.document.artifacts.first(where: { $0.identity.id == id }) else {
            throw WorkspaceRevisionStoreError.missingArtifact
        }
        return artifact
    }
}

/// Juniper after Let your apps ask, registered under its own name and
/// published to a new repository inside its own fixture.
@MainActor
private struct PublishedJuniper {
    let fixture: LaunchpadFixture
    let workspaceID: WorkspaceObjectID
    let remote: URL

    init() async throws {
        let fixture = try await LaunchpadFixture(.juniper)
        do {
            let remote = fixture.world.home.root.appending(path: "library.git", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try GitTestFixture.git(["init", "--bare", "--initial-branch", "main", remote.path(percentEncoded: false)], in: remote)
            let workspace = try await fixture.sample(.afterAsk).workspace
            _ = try await workspace.service.registerDevice(
                .init(expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper"))
            let transport = try await GitWorkspaceTransport.enroll(
                remote: remote.path(percentEncoded: false),
                checkout: fixture.world.home.root.appending(path: "juniper-checkout", directoryHint: .isDirectory),
                runner: ProcessCommandRunner(timeout: .seconds(60), homeURL: fixture.home))
            let coordinator = WorkspaceSyncCoordinator(
                store: workspace.store, transport: transport, writerID: WorkspaceObjectID(), contentStore: workspace.contentStore)
            _ = try await coordinator.sync()
            self.fixture = fixture
            self.workspaceID = workspace.store.workspaceID
            self.remote = remote
        } catch {
            fixture.remove()
            throw error
        }
    }
}

/// A join's runner: the system's own tools (git, tar) run for real, against
/// the repository on disk; every app's command is answered from the sample
/// world's script.
private struct JoinRunner: CommandRunning {
    let tools: ScriptedCommandRunner
    let homeURL: URL

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        if executable.hasPrefix("/usr/bin/") {
            return try await ProcessCommandRunner(timeout: .seconds(60), homeURL: homeURL)
                .run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        }
        return try await tools.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}

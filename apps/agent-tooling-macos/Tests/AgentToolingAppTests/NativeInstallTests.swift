import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A client's own package, from the client's report to the command that
/// installs it. Nothing here runs a real client: a fake tool stands in and
/// writes down what it was asked.
@Suite("Native package install") @MainActor
struct NativeInstallTests {
    static let route = "example@vendor"

    /// Every package Codex and Claude Code already held was planned as an
    /// install, forever, because presence was measured as a folder under a
    /// skill root. The client's own report is what says it is there.
    @Test func aPackageTheClientAlreadyReportsIsNotPlannedAgain() async throws {
        let fixture = try await ShellRenderFixture(deviceObserver: Self.observer(reporting: "User"))
        defer { fixture.remove() }
        try await fixture.askForThePlugin()

        let plan = try #require(fixture.workspace.deployment.plan)
        #expect(plan.items.isEmpty)
        #expect(
            plan.exclusions.contains {
                $0.reason == .alreadyPresent && $0.artifactID == ShellRenderFixture.plugin
            })
    }

    /// Claude Code records a package installed for one project separately from
    /// one installed for the account; the account-wide request is not met.
    @Test func aPackageInstalledForOneProjectStillGetsPlannedForTheAccount() async throws {
        let fixture = try await ShellRenderFixture(deviceObserver: Self.observer(reporting: "Project"))
        defer { fixture.remove() }
        try await fixture.askForThePlugin()

        let plan = try #require(fixture.workspace.deployment.plan)
        #expect(plan.items.map(\.artifactID) == [ShellRenderFixture.plugin])
    }

    /// The whole chain, through the app's own wiring: the scan says the client
    /// is here, the plan builds the recorded command with the tool at the place
    /// it was found (Claude Code's installer layout, a link to a version-named
    /// file), the executor's policy lets that path through, and it runs.
    @Test func aRecordedInstallCommandRunsThroughTheLocatedTool() async throws {
        let fixture = try await ShellRenderFixture(deviceObserver: Self.observer(reporting: nil))
        defer { fixture.remove() }
        let log = try fixture.installFakeClaude()
        try await fixture.askForThePlugin()

        let plan = try #require(fixture.workspace.deployment.plan)
        let item = try #require(plan.items.first)
        guard case .installNativePackage(let route) = item.action else {
            Issue.record("expected a native install, got \(item.action)")
            return
        }
        #expect(route.externalPluginID == Self.route)

        let reviewed = await DeploymentPlanReviewer.review(
            plan: plan, snapshot: try #require(fixture.workspace.library.state?.snapshot),
            contentStore: try #require(fixture.workspace.contentStore), homeRoot: fixture.home)
        #expect(reviewed.command(for: item) == "claude plugin install \(Self.route) --scope user")
        #expect(reviewed.reasonNothingRuns(for: item) == nil)
        #expect(reviewed.stepsWithoutCommand == 0)

        await fixture.workspace.deployment.apply()

        #expect(fixture.workspace.deployment.errorMessage == nil)
        let results = fixture.workspace.deployment.results
        #expect(results.map(\.succeeded) == [1], "\(results.map(\.outputs))")
        #expect(results.map(\.failed) == [0])
        let asked = try String(contentsOf: log, encoding: .utf8)
        #expect(asked.contains("plugin install \(Self.route) --scope user"))
    }

    /// A step no command can be built for is still a step on the sheet, and
    /// the review says it will not run rather than letting the count claim it.
    @Test func aStepWithNoToolToRunItIsReportedAsNotRunning() async throws {
        let fixture = try await ShellRenderFixture(deviceObserver: Self.observer(reporting: nil))
        defer { fixture.remove() }
        try await fixture.askForThePlugin()

        let plan = try #require(fixture.workspace.deployment.plan)
        let item = try #require(plan.items.first)
        let reviewed = await DeploymentPlanReviewer.review(
            plan: plan, snapshot: try #require(fixture.workspace.library.state?.snapshot),
            contentStore: try #require(fixture.workspace.contentStore), homeRoot: fixture.home)

        #expect(reviewed.command(for: item) == nil)
        #expect(reviewed.reasonNothingRuns(for: item)?.contains("Claude Code") == true)
        #expect(reviewed.stepsWithoutCommand == 1)
        #expect(reviewed.headline?.contains("1 step cannot run yet") == true)
    }

    /// The fixture's plugin has a Claude Code route only. Asked for in Codex as
    /// well, that destination is excluded for want of a route, and the Claude
    /// Code command must still be built: every package with a foreign-client
    /// assignment used to lose its command to the other destination's issue.
    @Test func anAssignmentToAClientWithNoRouteDoesNotBlockTheOneWithARoute() async throws {
        let fixture = try await ShellRenderFixture(deviceObserver: Self.observer(reporting: nil, codexToo: true))
        defer { fixture.remove() }
        _ = try fixture.installFakeClaude()
        try await fixture.askForThePlugin(alsoIn: .codexCLI)

        let plan = try #require(fixture.workspace.deployment.plan)
        #expect(plan.items.map(\.surface) == [.claudeCode])
        #expect(
            plan.exclusions.contains {
                $0.reason == .missingNativeRoute && $0.artifactID == ShellRenderFixture.plugin
            })
        let item = try #require(plan.items.first)
        let reviewed = await DeploymentPlanReviewer.review(
            plan: plan, snapshot: try #require(fixture.workspace.library.state?.snapshot),
            contentStore: try #require(fixture.workspace.contentStore), homeRoot: fixture.home)
        #expect(reviewed.command(for: item) == "claude plugin install \(Self.route) --scope user")
        #expect(reviewed.stepsWithoutCommand == 0)
    }

    /// Claude Code, present and answering, and optionally already reporting the
    /// fixture's plugin at one scope; Codex absent, or present the same way.
    private static func observer(reporting scope: String?, codexToo: Bool = false) -> StubDeviceObserver {
        var claude = ShellRenderFixture.observation(
            .claudeCode, installed: true, commandAvailable: true, version: "2.1.268")
        // What the real scan records for Claude Code; without it the client has
        // no plugin component and the request is excluded before planning.
        claude.capabilities.supportsPluginInstall = true
        if let scope {
            claude.pluginMetadata[route] = .init(
                name: "Example Plugin", source: "test", scope: scope, enabled: true)
        }
        var codex = ShellRenderFixture.observation(
            .codexCLI, installed: codexToo, commandAvailable: codexToo, version: codexToo ? "0.153.4" : nil)
        codex.capabilities.supportsPluginInstall = codexToo
        return StubDeviceObserver(observations: [claude, codex])
    }
}

extension ShellRenderFixture {
    /// Records the scan, asks for the plugin in Claude Code (and anywhere else
    /// named), and prepares.
    fileprivate func askForThePlugin(alsoIn surfaces: TargetSurface...) async throws {
        await workspace.device.refresh()
        #expect(workspace.device.errorMessage == nil)
        await workspace.library.reviewAssignments(
            artifactIDs: [Self.plugin],
            destinations: ([.claudeCode] + surfaces).map { .init(surface: $0, scope: .user) })
        await workspace.library.applyReviewedAssignments()
        #expect(workspace.library.errorMessage == nil)
        await workspace.deployment.prepare()
        #expect(workspace.deployment.errorMessage == nil)
    }

    /// Claude Code's installer layout in this fixture's home: the binary under
    /// a version number, and `~/.local/bin/claude` pointing at it. The fake
    /// tool appends what it was asked to a log and exits cleanly.
    fileprivate func installFakeClaude() throws -> URL {
        let log = home.appending(path: "claude-was-asked.txt")
        let versioned = home.appending(path: ".local/share/claude/versions/2.1.268")
        try FileManager.default.createDirectory(
            at: versioned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(log.path)\"\n".utf8).write(to: versioned)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versioned.path)
        let link = home.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: versioned)
        return log
    }
}

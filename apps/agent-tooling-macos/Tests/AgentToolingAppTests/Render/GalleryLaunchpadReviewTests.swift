import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The review panel in the gallery, in the stage's own window, named for the
/// mockup it pairs with (`s12-review`): ready, the plain-↩ hint, mid-install,
/// installed, and stale on Juniper; and You joined's five-step review on
/// Cedar. Nothing it draws runs an app's own tool: the install's commands are
/// answered by a script.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad review", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadReviewTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let source = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadReviewPanel.swift"

    @Test func theReviewOnJuniper() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, review) = try await Self.presented(fixture)

            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "ready", appearance: appearance, source: Self.source)

            flow.showCommandReturnHint()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "plain return", appearance: appearance, source: Self.source)

            // Mid-install: the copy into Codex done, Codex's connection
            // running, Claude Code's steps waiting.
            let gate = GatedCommandRunner()
            fixture.scriptReviewCommands(in: try #require(flow.workspace), runner: gate)
            review.now = { ClientHomeFixture.now.addingTimeInterval(LaunchpadFixture.installMinutes * 60) }
            let install = Task { await review.install() }
            await gate.waitUntilCalled()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "installing", appearance: appearance, source: Self.source)
            gate.release()
            await install.value
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "installed", appearance: appearance, source: Self.source)
        }
    }

    @Test func aStaleReview() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, review) = try await Self.presented(fixture)
            // Another write lands while the panel is open.
            let workspace = try #require(flow.workspace)
            _ = try await workspace.service.registerDevice(
                .init(expectedRevisionID: try fixture.head(of: workspace), deviceID: workspace.store.deviceID, name: "Juniper"))
            fixture.scriptReviewCommands(in: workspace, runner: fixture.reviewRunner())
            await review.install()
            #expect(review.phase == .stale)
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "stale", appearance: appearance, source: Self.source)
        }
    }

    @Test func youJoinedsReviewOnCedar() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture(.cedar)
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .cedarJoined)
            defer { sample.remove() }
            let review = ScopedPlanReview(workspace: sample.workspace, scope: .wholePlan, deviceName: "Cedar")
            flow.presentReview(review, returnTo: nil)
            await review.prepare()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "j02-review", state: "ready", appearance: appearance, source: Self.source)
        }
    }

    /// The shared sheet on Juniper's whole plan: the step left alone drawn in
    /// its app's group, Install answering only ⌘↩; before its read, and once
    /// it has read the plan.
    @Test func theSharedSheet() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let sample = try await fixture.sample(.afterAsk)
            fixture.scriptReviewCommands(in: sample.workspace, runner: RefusingCommandRunner())
            await sample.workspace.deployment.prepare()
            let plan = try #require(sample.workspace.deployment.plan)
            try gallerySnapshot(
                PlanReviewSheet(workspace: sample.workspace, plan: plan), area: "Apps · Clients", screen: "Plan review sheet",
                state: "launchpad sample, one left alone", size: SheetSize.xlarge, appearance: appearance,
                source: "Sources/AgentToolingApp/PlanReviewSheet.swift")
            let review = ScopedPlanReview(workspace: sample.workspace, reviewing: plan)
            await review.prepare()
            try gallerySnapshot(
                PlanReviewSheet(workspace: sample.workspace, review: review), area: "Apps · Clients",
                screen: "Plan review sheet", state: "launchpad sample, read", size: SheetSize.xlarge,
                appearance: appearance, source: "Sources/AgentToolingApp/PlanReviewSheet.swift")
        }
    }

    /// A connection that replaces a registration Agent Tooling made (a
    /// receipt proves it): both commands in one well, the old copy named.
    /// Without that proof the same step is left alone.
    @Test func aReplacementStep() async throws {
        for appearance in Self.both {
            for proven in [true, false] {
                let fixture = try await LaunchpadFixture()
                defer { fixture.remove() }
                let (flow, sample) = try await fixture.flow(at: .afterAsk)
                let workspace = sample.workspace
                try await fixture.registerAnotherCopyInClaudeCode(in: workspace)
                if proven { try fixture.recordThatAgentToolingSetUpItsConnection(in: .claudeCode, workspace: workspace) }
                fixture.scriptReviewCommands(in: workspace, runner: fixture.replacementRunner())
                let review = ScopedPlanReview(workspace: workspace, scope: .wholePlan, deviceName: "Juniper")
                flow.presentReview(review, returnTo: nil)
                await review.prepare()
                try galleryStageSnapshot(
                    fixture.stage(flow), screen: "s12-review",
                    state: proven ? "replacing a registration" : "a registration left alone", appearance: appearance,
                    source: Self.source)
            }
        }
    }

    /// The two states that end without an install: every step left alone,
    /// so Continue; and an install stopped before it began.
    @Test func theStatesWithNothingToInstall() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .afterAsk)
            let frontendDesign = try #require(sample.artifact("frontend-design"))
            let alone = ScopedPlanReview(
                workspace: sample.workspace, scope: .artifacts([frontendDesign.identity.id]), deviceName: "Juniper",
                libraryDecisions: flow.decisions)
            flow.presentReview(alone, returnTo: nil)
            await alone.prepare()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "nothing can run", appearance: appearance, source: Self.source)

            let (_, review) = try await Self.presented(fixture, flow: flow, sample: sample)
            fixture.scriptReviewCommands(in: sample.workspace, runner: fixture.reviewRunner())
            let installing = review.begin()
            review.stop()
            await installing?.value
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "s12-review", state: "did not run", appearance: appearance, source: Self.source)
        }
    }

    /// The stage at Let your apps ask, its review up and read.
    private static func presented(_ fixture: LaunchpadFixture) async throws -> (LaunchpadFlow, ScopedPlanReview) {
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        return try await presented(fixture, flow: flow, sample: sample)
    }

    /// `flow`'s review of the whole plan, up and read.
    private static func presented(
        _ fixture: LaunchpadFixture, flow: LaunchpadFlow, sample: LaunchpadSample
    ) async throws -> (LaunchpadFlow, ScopedPlanReview) {
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        return (flow, review)
    }
}

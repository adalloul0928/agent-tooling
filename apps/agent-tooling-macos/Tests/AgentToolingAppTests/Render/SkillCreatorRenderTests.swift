import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The creator draws before anything has been asked of an assistant, while a
/// conversation is waiting for a draft, once a package is waiting to be read,
/// and when the client's skill creator has to be installed first.
///
/// The sheet is the one surface in the app that can start a `claude` or `codex`
/// process, so these tests also prove the opposite of the usual claim: laying
/// it out asks for nothing. A render that ran a client would do it on
/// somebody's Mac too, before they typed a word.
@Suite("Skill creator renders")
@MainActor
struct SkillCreatorRenderTests {
    @Test(arguments: [ClientKind.claude, .codex])
    func theCreatorDrawsBeforeAnythingIsAsked(client: ClientKind) async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let drafting = StubSkillDrafting()
        let installer = RecordingSkillCreatorInstalling()

        try expectDrawn(
            SkillCreatorSheet(
                workspace: fixture.workspace, drafting: drafting, installing: installer, client: client,
                onCreated: { _, _ in }))

        #expect(drafting.createCount == 0, "drawing the creator asked \(client.rawValue) for a draft")
        #expect(installer.installedClients.isEmpty, "drawing the creator installed something")
    }

    @Test func theChooserDrawsAndOffersOnlyManagedAssistants() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let both = try rasterize(SkillCreationChooserSheet(managedClients: [.claude, .codex]) { _ in })
        try expectDrawn(SkillCreationChooserSheet(managedClients: [.claude, .codex]) { _ in })
        let codexOnly = try rasterize(SkillCreationChooserSheet(managedClients: [.codex]) { _ in })

        // A disabled option is drawn differently, so a chooser that dims
        // Claude must not look like one that offers it.
        #expect(both.tiffRepresentation != codexOnly.tiffRepresentation, "an unmanaged assistant was still offered")
    }

    @Test func theCreatorDrawsTheConversationWhileNoDraftExists() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(client: .claude, instruction: "Write a release-readiness skill.", targets: [.claude])
        let drafting = StubSkillDrafting(script: [.reply("Which release checks matter most to you?")])
        let asking = fixture.skillDraftSession(drafting)
        await asking.start(request)
        #expect(asking.hasConversation)
        #expect(asking.result == nil)

        let conversation = try rasterize(
            SkillCreatorSheet(workspace: fixture.workspace, session: asking, client: .claude, onCreated: { _, _ in }))
        try expectDrawn(
            SkillCreatorSheet(workspace: fixture.workspace, session: asking, client: .claude, onCreated: { _, _ in }))
        let blank = try rasterize(
            SkillCreatorSheet(
                workspace: fixture.workspace, drafting: StubSkillDrafting(), client: .claude, onCreated: { _, _ in }))

        #expect(conversation.tiffRepresentation != blank.tiffRepresentation, "the exchange changed nothing on screen")
        #expect(drafting.createCount == 1, "the render took another turn")
    }

    @Test func theCreatorDrawsTheGeneratedPackageForReview() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(instruction: "Write a release-readiness skill.", targets: [.codex])
        let staged = try fixture.stageSkillDraft(request: request)
        let drafting = StubSkillDrafting(answer: staged)
        let reviewing = fixture.skillDraftSession(drafting)
        await reviewing.start(request)
        #expect(reviewing.result != nil)

        let review = try rasterize(
            SkillCreatorSheet(
                workspace: fixture.workspace, session: reviewing, client: .codex, onCreated: { _, _ in }))
        try expectDrawn(
            SkillCreatorSheet(
                workspace: fixture.workspace, session: reviewing, client: .codex, onCreated: { _, _ in }))

        // The blank-frame check passes on the chrome alone, so the package has
        // to be shown to have changed something: a review pane that drew the
        // empty draft pane would draw exactly what the blank creator draws.
        let blank = try rasterize(
            SkillCreatorSheet(
                workspace: fixture.workspace, drafting: StubSkillDrafting(), client: .codex, onCreated: { _, _ in }))
        #expect(
            review.tiffRepresentation != blank.tiffRepresentation,
            "the generated package changed nothing on screen")
        #expect(drafting.createCount == 1, "the render generated a second draft")
    }

    @Test func theCreatorOffersTheInstallWhenTheSkillCreatorIsMissing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let install = [
            SkillCreatorInstallCommand(
                title: "Install skill-creator", executable: "claude",
                arguments: SkillCreatorCommandShapes.claudeSkillCreatorInstallArguments)
        ]
        let drafting = StubSkillDrafting(availability: [
            .claude: .missing(reason: "Claude Code does not have the skill-creator plugin installed.", install: install)
        ])
        let installer = RecordingSkillCreatorInstalling()
        let missing = fixture.skillDraftSession(drafting, installing: installer)
        await missing.checkAvailability(for: .claude)

        let offer = try rasterize(
            SkillCreatorSheet(workspace: fixture.workspace, session: missing, client: .claude, onCreated: { _, _ in }))
        try expectDrawn(
            SkillCreatorSheet(workspace: fixture.workspace, session: missing, client: .claude, onCreated: { _, _ in }))
        let ready = fixture.skillDraftSession(StubSkillDrafting())
        await ready.checkAvailability(for: .claude)
        let blank = try rasterize(
            SkillCreatorSheet(workspace: fixture.workspace, session: ready, client: .claude, onCreated: { _, _ in }))

        #expect(offer.tiffRepresentation != blank.tiffRepresentation, "the missing creator changed nothing on screen")
        // Offering the install is not running it.
        #expect(installer.installedClients.isEmpty, "drawing the offer ran the install")
        #expect(drafting.createCount == 0)
    }

    /// The route a queued request arrives on. Opening the creator for one reads
    /// the payload behind the row; it must not decide the row.
    @Test func openingAQueuedRequestReadsItsPayloadAndDecidesNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let queue = RecordingPendingRequestQueue(requests: [queued.request])
        let session = fixture.skillDraftSession(StubSkillDrafting(), queue: queue)

        let loaded = await session.loadRequest(id: queued.request.id)

        try expectDrawn(
            SkillCreatorSheet(
                workspace: fixture.workspace, session: session,
                pendingRequestID: queued.request.id, onCreated: { _, _ in }))
        #expect(loaded?.instruction == queued.draft.instruction)
        #expect(queue.resolvedIDs.isEmpty)
        #expect(queue.pending.count == 1)
    }
}

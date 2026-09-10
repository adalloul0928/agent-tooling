import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The creator draws before anything has been asked of Codex, and again once a
/// package is waiting to be read.
///
/// The sheet is the one surface in the app that can start a Codex process, so
/// these tests also prove the opposite of the usual claim: laying it out asks
/// for nothing. A render that ran `codex` would do it on somebody's Mac too,
/// before they typed a word.
@Suite("Codex skill creator renders")
@MainActor
struct CodexSkillCreatorRenderTests {
    @Test func theCreatorDrawsBeforeAnythingIsGenerated() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let drafting = StubCodexSkillDrafting()

        try expectDrawn(
            CodexSkillCreatorSheet(
                workspace: fixture.workspace, drafting: drafting, onCreated: { _, _ in }))

        #expect(drafting.createCount == 0, "drawing the creator asked Codex for a draft")
    }

    @Test func theCreatorDrawsTheGeneratedPackageForReview() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = CodexSkillDraftRequest(instruction: "Write a release-readiness skill.", targets: [.codex])
        let staged = try fixture.stageSkillDraft(request: request)
        let drafting = StubCodexSkillDrafting(answer: staged)
        let reviewing = fixture.skillDraftSession(drafting)
        await reviewing.generate(request)
        #expect(reviewing.result != nil)

        let review = try rasterize(
            CodexSkillCreatorSheet(
                workspace: fixture.workspace, session: reviewing, onCreated: { _, _ in }))
        try expectDrawn(
            CodexSkillCreatorSheet(
                workspace: fixture.workspace, session: reviewing, onCreated: { _, _ in }))

        // The blank-frame check passes on the chrome alone, so the package has
        // to be shown to have changed something: a review pane that drew the
        // authoring form would draw exactly what the empty creator draws.
        let authoring = try rasterize(
            CodexSkillCreatorSheet(
                workspace: fixture.workspace, drafting: StubCodexSkillDrafting(), onCreated: { _, _ in }))
        #expect(
            review.tiffRepresentation != authoring.tiffRepresentation,
            "the generated package changed nothing on screen")
        #expect(drafting.createCount == 1, "the render generated a second draft")
    }

    /// The route a queued request arrives on. Opening the creator for one reads
    /// the payload behind the row; it must not decide the row.
    @Test func openingAQueuedRequestReadsItsPayloadAndDecidesNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let queue = RecordingPendingRequestQueue(requests: [queued.request])
        let session = fixture.skillDraftSession(StubCodexSkillDrafting(), queue: queue)

        let loaded = await session.loadRequest(id: queued.request.id)

        try expectDrawn(
            CodexSkillCreatorSheet(
                workspace: fixture.workspace, session: session,
                pendingRequestID: queued.request.id, onCreated: { _, _ in }))
        #expect(loaded?.instruction == queued.draft.instruction)
        #expect(queue.resolvedIDs.isEmpty)
        #expect(queue.pending.count == 1)
    }
}

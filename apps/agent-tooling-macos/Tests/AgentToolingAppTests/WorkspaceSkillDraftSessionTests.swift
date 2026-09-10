import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Codex writes into a staging folder, and only accepting the draft puts
/// anything in the library.
///
/// Every test here turns on the same question: what has changed on this Mac at
/// each step. Generating changes nothing durable, closing changes nothing
/// durable, and accepting adds exactly one skill and assigns it nowhere.
@MainActor
struct WorkspaceSkillDraftSessionTests {
    @Test func generatingStagesADraftAndLeavesTheLibraryAlone() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = CodexSkillDraftRequest(instruction: "Write a release-readiness skill.", targets: [.codex])
        let staged = try fixture.stageSkillDraft(request: request)
        let drafting = StubCodexSkillDrafting(answer: staged)
        let session = fixture.skillDraftSession(drafting)
        let before = try #require(fixture.workspace.library.state).library.rows.count

        await session.generate(request)

        #expect(drafting.createCount == 1)
        #expect(session.result?.skillName == "codex-release-readiness")
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.isBusy == false)
        // A staged draft is not a library item, and nothing here has asked for
        // one to be used anywhere.
        await fixture.workspace.library.refresh()
        #expect(try #require(fixture.workspace.library.state).library.rows.count == before)
    }

    @Test func aRefusedGenerationSaysWhatCodexRefusedAndStagesNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let drafting = StubCodexSkillDrafting(
            failure: StubDraftFailure.refused("The installed Codex Skill Creator was not found."))
        let session = fixture.skillDraftSession(drafting)

        await session.generate(.init(instruction: "Write a release-readiness skill.", targets: [.codex]))

        #expect(session.result == nil)
        #expect(session.errorMessage == "The installed Codex Skill Creator was not found.")
    }

    @Test func acceptingTheDraftAdmitsOneSkillAndAssignsItNowhere() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let staged = try fixture.stageSkillDraft(request: queued.draft)
        let drafting = StubCodexSkillDrafting(answer: staged)
        let queue = RecordingPendingRequestQueue(requests: [queued.request])
        let workspace = try await fixture.workspaceHoldingContent()
        let session = fixture.skillDraftSession(drafting, queue: queue, in: workspace)
        await session.generate(queued.draft)

        let adopted = try #require(
            await session.adopt(resolving: queued.request.id),
            "the draft was not adopted: \(session.errorMessage ?? "no message")")

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let model = try #require(workspace.library.state).library
        let row = try #require(model.rows.first { $0.artifactID == adopted })
        #expect(row.kind == .skill)
        #expect(row.displayName == "Codex Release Readiness")
        // Admitted, and nowhere near a client: where a new skill is used is the
        // separate choice the next sheet asks for.
        #expect(row.requestedAssignments.isEmpty)
        // The stage and the request that asked for it go together, once.
        #expect(drafting.discardedDraftIDs == [staged.id])
        #expect(queue.resolvedIDs == [queued.request.id])
        #expect(fixture.savedDraftRequest(queued.draft.id) == nil)
        #expect(session.result == nil)
    }

    @Test func aDraftThatNoLongerMatchesWhatWasReviewedIsRefused() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = CodexSkillDraftRequest(instruction: "Write a release-readiness skill.", targets: [.codex])
        let staged = try fixture.stageSkillDraft(request: request, name: "codex-release-readiness")
        // The files on disk say one thing; the reviewed draft claims another.
        var renamed = staged
        renamed.skillName = "something-else"
        let workspace = try await fixture.workspaceHoldingContent()
        let session = fixture.skillDraftSession(StubCodexSkillDrafting(answer: renamed), in: workspace)
        await session.generate(request)

        let adopted = await session.adopt(resolving: nil)

        #expect(adopted == nil)
        #expect(session.errorMessage?.contains("no longer match") == true)
        await workspace.library.refresh()
        let model = try #require(workspace.library.state).library
        #expect(!model.rows.contains { $0.displayName == "Something Else" })
    }

    @Test func closingWithoutAcceptingLeavesAQueuedRequestOpenable() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let staged = try fixture.stageSkillDraft(request: queued.draft)
        let drafting = StubCodexSkillDrafting(answer: staged)
        let queue = RecordingPendingRequestQueue(requests: [queued.request])
        let session = fixture.skillDraftSession(drafting, queue: queue)
        await session.generate(queued.draft)

        await session.abandon(requestID: queued.draft.id)

        #expect(drafting.discardedDraftIDs == [staged.id])
        // Nothing was decided, so the row and the payload it opens both stay.
        #expect(queue.resolvedIDs.isEmpty)
        #expect(fixture.savedDraftRequest(queued.draft.id) == queued.draft)
        #expect(session.result == nil)
    }

    @Test func closingWithoutAcceptingDropsARequestNothingIsWaitingOn() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let seeded = CodexSkillDraftRequest(instruction: "Write a changelog skill.", targets: [.codex])
        #expect(await WorkspaceSkillDraftSeed.save(seeded, in: fixture.store))
        let drafting = StubCodexSkillDrafting()
        let session = fixture.skillDraftSession(drafting)

        await session.abandon(requestID: seeded.id)

        // Never generated, so the stage rather than a package is put away, and
        // a payload no review row owns does not outlive the sheet.
        #expect(drafting.discardedRequestIDs == [seeded.id])
        #expect(fixture.savedDraftRequest(seeded.id) == nil)
    }

    @Test func startingOverKeepsTheRequestSoItCanBeDescribedAgain() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let staged = try fixture.stageSkillDraft(request: queued.draft)
        let drafting = StubCodexSkillDrafting(answer: staged)
        let session = fixture.skillDraftSession(drafting, queue: RecordingPendingRequestQueue(requests: [queued.request]))
        await session.generate(queued.draft)

        await session.startOver()

        #expect(session.result == nil)
        #expect(drafting.discardedDraftIDs == [staged.id])
        #expect(fixture.savedDraftRequest(queued.draft.id) == queued.draft)
    }

    @Test func theCreatorOpensWhatWasActuallyAskedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest(
            instruction: "Turn a week of merged pull requests into a changelog entry.")
        let session = fixture.skillDraftSession(StubCodexSkillDrafting())

        let loaded = await session.loadRequest(id: queued.draft.id)

        #expect(loaded == queued.draft)
        #expect(session.errorMessage == nil)
    }

    @Test func aRequestWithNoPayloadSaysSoRatherThanOpeningAnEmptyCreator() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = fixture.skillDraftSession(StubCodexSkillDrafting())

        let loaded = await session.loadRequest(id: UUID())

        #expect(loaded == nil)
        #expect(session.errorMessage?.contains("no longer available") == true)
    }
}

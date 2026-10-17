import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// An assistant writes into a staging folder in conversation, and only
/// accepting the draft puts anything in the library.
///
/// Every test here turns on the same question: what has changed on this Mac at
/// each step. A turn changes nothing durable, closing changes nothing durable,
/// installing the creator changes only the client, and accepting adds exactly
/// one skill and assigns it nowhere.
@MainActor
struct WorkspaceSkillDraftSessionTests {
    @Test(arguments: [ClientKind.claude, .codex])
    func theFirstMessageOpensAConversationAndLeavesTheLibraryAlone(client: ClientKind) async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(
            client: client, instruction: "Write a release-readiness skill.", targets: [client])
        let staged = try fixture.stageSkillDraft(request: request)
        let drafting = StubSkillDrafting(answer: staged)
        let session = fixture.skillDraftSession(drafting)
        let before = try #require(fixture.workspace.library.state).library.rows.count

        await session.start(request)

        #expect(drafting.startedRequests.map(\.client) == [client])
        #expect(session.hasConversation)
        #expect(session.messages.map(\.role) == [.person, .assistant])
        #expect(session.messages.first?.text == "Write a release-readiness skill.")
        #expect(session.result?.skillName == "codex-release-readiness")
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.isBusy == false)
        // A staged draft is not a library item, and nothing here has asked for
        // one to be used anywhere.
        await fixture.workspace.library.refresh()
        #expect(try #require(fixture.workspace.library.state).library.rows.count == before)
    }

    @Test func aClarifyingQuestionShowsNoDraftAndTheAnswerContinuesTheSameConversation() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(client: .claude, instruction: "Make a skill for releases.", targets: [.claude])
        let staged = try fixture.stageSkillDraft(request: request)
        let drafting = StubSkillDrafting(script: [
            .reply("Which release checks matter most to you?"),
            .reply("Done — the draft covers tests, docs, and rollback notes.", draft: staged),
        ])
        let session = fixture.skillDraftSession(drafting)

        await session.start(request)
        #expect(session.hasConversation)
        #expect(session.result == nil)
        #expect(session.messages.last?.text == "Which release checks matter most to you?")

        await session.send("Tests, docs, rollback notes.", client: .claude)

        #expect(drafting.createCount == 1, "the answer started a second conversation")
        #expect(drafting.continuedReplies == ["Tests, docs, rollback notes."])
        #expect(session.messages.map(\.role) == [.person, .assistant, .person, .assistant])
        #expect(session.result?.skillName == "codex-release-readiness")
    }

    @Test func aConversationAnEarlierRunKeptIsPickedUpRatherThanStartedAgain() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(client: .claude, instruction: "Make a skill for releases.", targets: [.claude])
        let staged = try fixture.stageSkillDraft(request: request)
        let drafting = StubSkillDrafting(script: [.fail(StubDraftFailure.refused("a second start must not happen"))])
        drafting.keep(
            SkillDraftConversation(
                request: request, sessionID: UUID().uuidString.lowercased(),
                messages: [
                    SkillDraftMessage(role: .person, text: "Make a skill for releases."),
                    SkillDraftMessage(role: .assistant, text: "Done — the draft is at ./draft."),
                ]),
            draft: staged)
        let session = fixture.skillDraftSession(drafting)

        await session.start(request)

        #expect(drafting.createCount == 0, "the kept conversation was started over")
        #expect(session.hasConversation)
        #expect(session.messages.map(\.text) == ["Make a skill for releases.", "Done — the draft is at ./draft."])
        #expect(session.result?.skillName == "codex-release-readiness")
        #expect(session.errorMessage == nil)
    }

    @Test func aRefusedTurnSaysWhatTheClientRefusedAndStagesNothing() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let drafting = StubSkillDrafting(
            failure: StubDraftFailure.refused("Codex could not finish the turn (status 1): not signed in."))
        let session = fixture.skillDraftSession(drafting)

        await session.start(.init(instruction: "Write a release-readiness skill.", targets: [.codex]))

        #expect(session.result == nil)
        #expect(session.hasConversation == false, "a failed first turn left a conversation to continue")
        #expect(session.errorMessage == "Codex could not finish the turn (status 1): not signed in.")
        // The refusal is also in the transcript, where the person is looking.
        #expect(session.messages.last?.role == .note)
    }

    @Test func aNoteFromTheClientIsShownBesideItsReply() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(client: .claude, instruction: "Write a release-readiness skill.", targets: [.claude])
        let drafting = StubSkillDrafting(script: [
            .reply(
                "I tried to run the plugin's script and could not.",
                notes: ["Claude Code asked to use Bash and was refused: only files inside the draft folder may be written here."])
        ])
        let session = fixture.skillDraftSession(drafting)

        await session.start(request)

        #expect(session.messages.map(\.role) == [.person, .assistant, .note])
        #expect(session.messages.last?.text.contains("Bash") == true)
        #expect(session.errorMessage == nil)
    }

    @Test func aHalfWrittenDraftReadsAsNotReadyRatherThanAsFailure() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let request = SkillDraftRequest(client: .codex, instruction: "Write a release-readiness skill.", targets: [.codex])
        let drafting = StubSkillDrafting(script: [
            .reply("I started the package.", draftIssue: "The draft plugin manifest is invalid: name is missing.")
        ])
        let session = fixture.skillDraftSession(drafting)

        await session.start(request)

        #expect(session.result == nil)
        #expect(session.draftIssue?.contains("manifest") == true)
        #expect(session.errorMessage == nil)
        #expect(session.hasConversation, "a draft that needs another turn must still be continuable")
    }

    @Test func acceptingTheDraftAdmitsOneSkillAndAssignsItNowhere() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let staged = try fixture.stageSkillDraft(request: queued.draft)
        let drafting = StubSkillDrafting(answer: staged)
        let queue = RecordingPendingRequestQueue(requests: [queued.request])
        let workspace = try await fixture.workspaceHoldingContent()
        let session = fixture.skillDraftSession(drafting, queue: queue, in: workspace)
        await session.start(queued.draft)

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
        let request = SkillDraftRequest(instruction: "Write a release-readiness skill.", targets: [.codex])
        let staged = try fixture.stageSkillDraft(request: request, name: "codex-release-readiness")
        // The files on disk say one thing; the reviewed draft claims another.
        var renamed = staged
        renamed.skillName = "something-else"
        let workspace = try await fixture.workspaceHoldingContent()
        let session = fixture.skillDraftSession(StubSkillDrafting(answer: renamed), in: workspace)
        await session.start(request)

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
        let drafting = StubSkillDrafting(answer: staged)
        let queue = RecordingPendingRequestQueue(requests: [queued.request])
        let session = fixture.skillDraftSession(drafting, queue: queue)
        await session.start(queued.draft)

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
        let seeded = SkillDraftRequest(instruction: "Write a changelog skill.", targets: [.codex])
        #expect(await WorkspaceSkillDraftSeed.save(seeded, in: fixture.store))
        let drafting = StubSkillDrafting()
        let session = fixture.skillDraftSession(drafting)

        await session.abandon(requestID: seeded.id)

        // Never generated, so the stage rather than a package is put away, and
        // a payload no review row owns does not outlive the sheet.
        #expect(drafting.discardedRequestIDs == [seeded.id])
        #expect(fixture.savedDraftRequest(seeded.id) == nil)
    }

    @Test func startingOverClearsTheConversationAndKeepsTheRequestOpenable() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest()
        let staged = try fixture.stageSkillDraft(request: queued.draft)
        let drafting = StubSkillDrafting(answer: staged)
        let session = fixture.skillDraftSession(drafting, queue: RecordingPendingRequestQueue(requests: [queued.request]))
        await session.start(queued.draft)

        await session.startOver()

        #expect(session.result == nil)
        #expect(session.messages.isEmpty)
        #expect(session.hasConversation == false)
        #expect(drafting.discardedDraftIDs == [staged.id])
        #expect(fixture.savedDraftRequest(queued.draft.id) == queued.draft)
    }

    @Test func theCreatorOpensWhatWasActuallyAskedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let queued = try fixture.queueSkillDraftRequest(
            client: .claude,
            instruction: "Turn a week of merged pull requests into a changelog entry.")
        let session = fixture.skillDraftSession(StubSkillDrafting())

        let loaded = await session.loadRequest(id: queued.draft.id)

        #expect(loaded == queued.draft)
        #expect(loaded?.client == .claude)
        #expect(session.errorMessage == nil)
    }

    @Test func aRequestWithNoPayloadSaysSoRatherThanOpeningAnEmptyCreator() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = fixture.skillDraftSession(StubSkillDrafting())

        let loaded = await session.loadRequest(id: UUID())

        #expect(loaded == nil)
        #expect(session.errorMessage?.contains("no longer available") == true)
    }

    // MARK: - The skill creator itself

    @Test func aMissingSkillCreatorIsReportedWithItsInstallCommands() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let install = [
            SkillCreatorInstallCommand(
                title: "Install skill-creator", executable: "claude",
                arguments: SkillCreatorCommandShapes.claudeSkillCreatorInstallArguments)
        ]
        let drafting = StubSkillDrafting(availability: [
            .claude: .missing(reason: "Claude Code does not have the skill-creator plugin installed.", install: install),
            .codex: .available,
        ])
        let session = fixture.skillDraftSession(drafting)

        await session.checkAvailability(for: .claude)
        guard case .missing(let reason, let commands) = session.availability else {
            Issue.record("expected the creator to be reported missing, got \(String(describing: session.availability))")
            return
        }
        #expect(reason.contains("skill-creator"))
        #expect(commands == install)

        await session.checkAvailability(for: .codex)
        #expect(session.availability == .available)
    }

    @Test func installingTheSkillCreatorRunsExactlyTheClientsCommandsAndChecksAgain() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let install = [
            SkillCreatorInstallCommand(
                title: "Add the marketplace", executable: "claude",
                arguments: SkillCreatorCommandShapes.claudeOfficialMarketplaceAddArguments),
            SkillCreatorInstallCommand(
                title: "Install skill-creator", executable: "claude",
                arguments: SkillCreatorCommandShapes.claudeSkillCreatorInstallArguments),
        ]
        let drafting = StubSkillDrafting(availability: [
            .claude: .missing(reason: "Claude Code does not have the skill-creator plugin installed.", install: install)
        ])
        // A real install changes what the client reports; the stub has to be
        // told, the way the plugin file would change on disk.
        let installer = RecordingSkillCreatorInstalling(onInstall: { drafting.setAvailability(.available, for: .claude) })
        let session = fixture.skillDraftSession(drafting, installing: installer)
        await session.checkAvailability(for: .claude)

        await session.installSkillCreator(for: .claude)

        #expect(installer.installedClients == [.claude])
        #expect(installer.installedCommands == [install])
        #expect(session.availability == .available)
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        // Installing the creator is not a conversation, and it stages nothing.
        #expect(session.hasConversation == false)
        #expect(drafting.createCount == 0)
    }

    @Test func aFailedInstallSaysSoAndLeavesTheCreatorMissing() async throws {
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
        let installer = RecordingSkillCreatorInstalling(
            failure: SkillCreatorInstallError.stepFailed("claude exited with status 1. Not logged in."))
        let session = fixture.skillDraftSession(drafting, installing: installer)
        await session.checkAvailability(for: .claude)

        await session.installSkillCreator(for: .claude)

        #expect(session.errorMessage?.contains("Not logged in") == true)
        guard case .missing = session.availability else {
            Issue.record("a failed install must leave the creator reported missing")
            return
        }
    }

    @Test func nothingIsInstalledWhenTheClientKnowsNoInstallCommand() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let drafting = StubSkillDrafting(availability: [
            .codex: .missing(reason: "Codex's built-in skill creator was not found.", install: [])
        ])
        let installer = RecordingSkillCreatorInstalling()
        let session = fixture.skillDraftSession(drafting, installing: installer)
        await session.checkAvailability(for: .codex)

        await session.installSkillCreator(for: .codex)

        #expect(installer.installedClients.isEmpty)
    }
}

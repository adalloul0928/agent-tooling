import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// `status(of:)` is the one place the account rows and the banner ask whether
/// a shared choice is waiting to be applied here and whether this Mac is held
/// from applying it. These pin its three answers so the three views cannot
/// drift on what "not applied yet" means.
@Suite("Accounts · the per-key plan status")
@MainActor
struct WorkspaceAccountsSessionKeyStatusTests {
    @Test func aKeyWithNoSharedChoiceIsNeitherPendingNorHeld() async throws {
        let fixture = try await WorkspaceAccountsSessionTests.Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        let status = fixture.session.status(of: .init(.skillSync))
        #expect(status == .init(pending: false, held: nil))
    }

    @Test func aSavedChoiceThisMacCanFollowIsPending() async throws {
        let fixture = try await WorkspaceAccountsSessionTests.Fixture()
        defer { fixture.remove() }
        await fixture.session.read()
        #expect(await fixture.session.setChoice(.init(.skillSync), to: .off))
        let status = fixture.session.status(of: .init(.skillSync))
        #expect(status.pending)
        #expect(status.held == nil)
    }

    @Test func aChoiceThisMacCannotFollowIsHeldWithItsReason() async throws {
        var blocked = AccountObservation(
            provider: .chatGPT, signIn: .init(method: .subscription, plan: "plus"), contentsRead: true)
        blocked.writeBlocker = "Codex on this Mac reads its configuration from somewhere this app does not edit."
        let fixture = try await WorkspaceAccountsSessionTests.Fixture(chatGPT: blocked, codexInstalled: true)
        defer { fixture.remove() }
        await fixture.session.read()
        #expect(await fixture.session.setChoice(.init(.apps), to: .off))
        let status = fixture.session.status(of: .init(.apps))
        #expect(!status.pending)
        #expect(status.held?.reason == blocked.writeBlocker)
    }
}

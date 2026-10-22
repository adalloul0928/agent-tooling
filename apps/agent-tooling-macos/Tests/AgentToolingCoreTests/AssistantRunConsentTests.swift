import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Which of the assistant's own runs this Mac allows, and whether project
/// discovery reads Claude Code's history. Both are this Mac's choices, kept in
/// its device record; a store made before they existed has neither and keeps
/// doing what it did.
@Suite("Assistant run consent")
struct AssistantRunConsentTests {
    @Test func offRunsNothingAndExistingBehaviourIsWhatRanBefore() {
        #expect(AssistantRunConsent.off == .init(weeklyReview: false, dailyDeepDive: false, localInsights: false))
        #expect(AssistantRunConsent.existingBehaviour == .init(weeklyReview: true, dailyDeepDive: true, localInsights: false))
    }

    @Test func aStoreFromBeforeTheChoiceKeepsItsBehaviour() throws {
        let legacy = Data(#"{"automaticallyCheckHealth":true,"enabledClients":["Claude Code","Codex","Gemini CLI","Kiro CLI"]}"#.utf8)

        let preferences = try JSONDecoder().decode(DeviceWorkspacePreferences.self, from: legacy)

        #expect(preferences.assistantRuns == nil)
        #expect(preferences.findsProjectsFromClaudeHistory == nil)
        #expect(preferences.effectiveAssistantRuns == .existingBehaviour)
    }

    @Test func aChoiceIsInForceAsMade() {
        let weeklyOnly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)

        #expect(DeviceWorkspacePreferences(assistantRuns: .off).effectiveAssistantRuns == .off)
        #expect(DeviceWorkspacePreferences(assistantRuns: weeklyOnly).effectiveAssistantRuns == weeklyOnly)
    }

    /// An absent choice writes nothing, so a store this build opens without
    /// choosing is byte for byte what an older build wrote.
    @Test func anAbsentChoiceIsNotWritten() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(DeviceWorkspacePreferences()), as: UTF8.self)

        #expect(!text.contains("assistantRuns"))
        #expect(!text.contains("findsProjectsFromClaudeHistory"))
    }

    /// The strict device decoder refuses bytes it would not write itself, so
    /// a recorded choice must come back exactly as it went in.
    @Test(arguments: [
        AssistantRunConsent.off, .existingBehaviour,
        .init(weeklyReview: true, dailyDeepDive: false, localInsights: false),
        .init(weeklyReview: false, dailyDeepDive: false, localInsights: true),
    ])
    func aRecordedChoiceRoundTripsCanonically(consent: AssistantRunConsent) throws {
        var device = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        device.applicationState?.preferences.assistantRuns = consent
        device.applicationState?.preferences.findsProjectsFromClaudeHistory = false

        let bytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(bytes)

        #expect(decoded.applicationState?.preferences.assistantRuns == consent)
        #expect(decoded.applicationState?.preferences.findsProjectsFromClaudeHistory == false)
        #expect(try WorkspaceDocumentCoding.encodeDeviceState(decoded) == bytes)
    }

    @Test func aLegacyDeviceRecordStillDecodes() throws {
        let device = DeviceWorkspaceState(workspaceID: WorkspaceObjectID())
        let bytes = try WorkspaceDocumentCoding.encodeDeviceState(device)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("assistantRuns"))

        let decoded = try WorkspaceDocumentCoding.decodeDeviceState(bytes)

        #expect(decoded.applicationState?.preferences.assistantRuns == nil)
        #expect(decoded.applicationState?.preferences.effectiveAssistantRuns == .existingBehaviour)
    }

    /// A new setup records its choice in the workspace's first revision.
    @Test func aNewSetupRecordsItsChoiceInRevisionOne() async throws {
        let folder = try TemporaryFolder("assistant-run-consent")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let locator = try WorkspaceLocator(root: folder.url.appending(path: "support"))

        let store = try await locator.create(
            homeURL: folder.url, runner: RefusingCommandRunner(), registry: .init(adapters: []),
            preferences: .init(chosenClients: [], assistantRuns: .off, findsProjectsFromClaudeHistory: true))

        let preferences = try #require(try store.snapshot()?.device.applicationState?.preferences)
        #expect(preferences.assistantRuns == .off)
        #expect(preferences.findsProjectsFromClaudeHistory == true)
        #expect(preferences.chosenClients == [])
    }
}

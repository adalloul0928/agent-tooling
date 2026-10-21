import AgentToolingCore
import Testing

@testable import AgentToolingApp

/// What the shell's launch work may start, for every setup status and every
/// way the shell can open (plan §2.5, D27): nothing while a first run is on
/// the stage, no second check right after the stage's own, no network
/// catalog for a first run left before its preferences were seen, and the
/// assistant's runs exactly as this Mac allows them.
@Suite("Launch work policy")
struct LaunchWorkPolicyTests {
    private static let handedOff = ShellLaunchHints(justHandedOff: true)
    private static let opened = ShellLaunchHints()

    private static func preferences(checkOnOpen: Bool = true, runs: AssistantRunConsent? = nil) -> DeviceWorkspacePreferences {
        DeviceWorkspacePreferences(automaticallyCheckHealth: checkOnOpen, assistantRuns: runs)
    }

    // MARK: Each status

    @Test func aWorkspaceMadeBeforeSetupRecordedAnythingRunsAsItAlwaysDid() {
        let policy = LaunchWorkPolicy.decide(status: .legacy, preferences: Self.preferences(), hints: Self.opened)
        #expect(policy.startsShellWork)
        #expect(policy.checksApps)
        #expect(policy.auditsOnOpen)
        #expect(policy.auditMayScan)
        #expect(policy.allowsNetworkCatalogs)
        #expect(policy.consent == .existingBehaviour, "nil consent keeps today's weekly review and daily deep dive")
    }

    @Test func aFirstRunStillOnTheStageStartsNothing() {
        for step: LaunchpadStep in [.found, .library, .assistant, .behave, .macs] {
            let policy = LaunchWorkPolicy.decide(
                status: .inProgress(step), preferences: Self.preferences(runs: .existingBehaviour), hints: Self.opened)
            #expect(!policy.startsShellWork)
            #expect(!policy.checksApps && !policy.auditsOnOpen && !policy.auditMayScan && !policy.allowsNetworkCatalogs)
        }
    }

    @Test func theFirstShellAfterTheHandOffNeitherChecksNorAuditsAgain() {
        for status: SetupStatus in [
            .finished(path: .startHere, seenPreferences: true), .finished(path: .join, seenPreferences: true),
            .finished(path: .rerun, seenPreferences: false), .deferred(.library, path: .startHere, seenPreferences: false),
        ] {
            let policy = LaunchWorkPolicy.decide(status: status, preferences: Self.preferences(), hints: Self.handedOff)
            #expect(policy.startsShellWork, "\(status)")
            #expect(!policy.checksApps, "\(status): the stage has just read this Mac's apps")
            #expect(!policy.auditsOnOpen, "\(status): the stage has just audited them")
        }
    }

    @Test func aLaterLaunchOfAFinishedSetupChecksAsThisMacChose() {
        for path: LaunchpadPath in [.startHere, .join, .rerun] {
            let on = LaunchWorkPolicy.decide(
                status: .finished(path: path, seenPreferences: true), preferences: Self.preferences(), hints: Self.opened)
            #expect(on.checksApps && on.auditsOnOpen && on.auditMayScan && on.allowsNetworkCatalogs)
            let off = LaunchWorkPolicy.decide(
                status: .finished(path: path, seenPreferences: true), preferences: Self.preferences(checkOnOpen: false),
                hints: Self.opened)
            #expect(!off.checksApps && !off.auditMayScan, "Check my apps each time Agent Tooling opens is off")
            #expect(off.auditsOnOpen, "the audit still runs, over the last check")
        }
    }

    /// D27: the catalogs wait only for a first run (Start here or Join) left
    /// for later before How Agent Tooling behaves was seen.
    @Test func aFirstRunLeftBeforeItsPreferencesAsksNoCatalog() {
        for path: LaunchpadPath in [.startHere, .join] {
            let before = LaunchWorkPolicy.decide(
                status: .deferred(.library, path: path, seenPreferences: false), preferences: Self.preferences(), hints: Self.opened)
            #expect(!before.allowsNetworkCatalogs)
            #expect(before.startsShellWork && before.checksApps && before.auditsOnOpen)
            let after = LaunchWorkPolicy.decide(
                status: .deferred(.macs, path: path, seenPreferences: true), preferences: Self.preferences(), hints: Self.opened)
            #expect(after.allowsNetworkCatalogs)
        }
        // A rerun is never left for later; a record that reads as one (a
        // newer build's state, read tolerantly) holds nothing back.
        let rerun = LaunchWorkPolicy.decide(
            status: .deferred(.apps, path: .rerun, seenPreferences: false), preferences: Self.preferences(), hints: Self.opened)
        #expect(rerun.allowsNetworkCatalogs)
        #expect(!LaunchWorkPolicy.allowsNetworkCatalogs(status: .inProgress(.behave)))
        #expect(LaunchWorkPolicy.allowsNetworkCatalogs(status: .legacy))
    }

    @Test func aWindowOpenedAgainInTheSameLaunchDoesNotCheckAgain() {
        for status: SetupStatus in [.legacy, .finished(path: .startHere, seenPreferences: true)] {
            let again = LaunchWorkPolicy.decide(
                status: status, preferences: Self.preferences(), hints: Self.opened, checkedThisLaunch: true)
            #expect(!again.checksApps, "\(status)")
            #expect(again.auditsOnOpen, "\(status): the audit is a second's work and keeps the list current")
        }
    }

    // MARK: Consent

    @Test func consentIsAlwaysTheRecordedChoiceOrTodaysRuns() {
        let weekly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)
        for status: SetupStatus in [
            .legacy, .finished(path: .startHere, seenPreferences: true), .deferred(.assistant, path: .join, seenPreferences: false),
        ] {
            #expect(
                LaunchWorkPolicy.decide(status: status, preferences: Self.preferences(), hints: Self.opened).consent == .existingBehaviour)
            #expect(LaunchWorkPolicy.decide(status: status, preferences: Self.preferences(runs: .off), hints: Self.opened).consent == .off)
            #expect(
                LaunchWorkPolicy.decide(status: status, preferences: Self.preferences(runs: weekly), hints: Self.opened).consent == weekly)
        }
    }

    /// D27's rerun rows: a workspace made before setup recorded anything
    /// keeps today's runs through a rerun that is left early (nothing is
    /// recorded), and through one that reaches Done (a finished rerun record,
    /// with the runs Let your assistant help recorded).
    @Test func aRerunOfAnOlderWorkspaceKeepsItsRunsUntilAChoiceIsRecorded() {
        let left = LaunchWorkPolicy.decide(status: .legacy, preferences: Self.preferences(), hints: Self.opened)
        #expect(left.consent == .existingBehaviour)
        #expect(left.allowsNetworkCatalogs && left.auditsOnOpen)

        let done = LaunchWorkPolicy.decide(
            status: .finished(path: .rerun, seenPreferences: true), preferences: Self.preferences(runs: .existingBehaviour),
            hints: Self.opened)
        #expect(done.consent == .existingBehaviour)
        #expect(done.allowsNetworkCatalogs && done.checksApps && done.auditsOnOpen)

        let turnedOff = LaunchWorkPolicy.decide(
            status: .finished(path: .rerun, seenPreferences: true), preferences: Self.preferences(runs: .off), hints: Self.opened)
        #expect(turnedOff.consent == .off)
    }
}

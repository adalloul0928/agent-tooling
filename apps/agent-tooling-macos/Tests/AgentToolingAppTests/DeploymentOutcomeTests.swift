import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What a reviewed install did, from how each of its steps ended: an app is
/// installed only when every one of its steps ran and succeeded, a failure is
/// charged to the app it happened in with its own words, a step the install
/// never ran keeps its app from reading as installed, and the result keeps
/// the shipped wording.
@Suite("Deployment outcome")
struct DeploymentOutcomeTests {
    private let finishedAt = ClientHomeFixture.now.addingTimeInterval(11 * 60)

    @Test func everyStepSucceedingInstallsToEveryApp() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.codex, .succeeded), (.claude, .succeeded), (.claude, .succeeded)],
            finishedAt: finishedAt)

        #expect(outcome.installed == [.codex, .claude])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.succeededSteps == 4)
        #expect(outcome.failedSteps == 0)
        #expect(outcome.summary == "Installed to Claude Code and Codex.")
        #expect(outcome.receiptLine == "Installed 4 changes · \(finishedAt.formatted(date: .omitted, time: .shortened))")
    }

    @Test func aFailedStepChargesItsAppWithItsOwnWords() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.claude, .failed("claude: plugin not found")), (.claude, .succeeded)],
            finishedAt: finishedAt)

        #expect(outcome.installed == [.codex])
        #expect(outcome.failed == [.claude: "claude: plugin not found"])
        #expect(outcome.succeededSteps == 2)
        #expect(outcome.failedSteps == 1)
        #expect(outcome.summary == "Installed to 1 of 2 apps.")
    }

    /// A step an install stopped before never makes its app read as
    /// installed, is not a failure, and the result says the install stopped.
    @Test func aStepThatNeverRanKeepsItsAppFromReadingAsInstalled() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.claude, .notRun)], finishedAt: finishedAt)

        #expect(outcome.installed == [.codex])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.unfinished == [.claude])
        #expect(outcome.failedSteps == 0)
        #expect(outcome.stoppedSteps == 1)
        #expect(!outcome.isComplete)
        #expect(outcome.summary == "Stopped after 1 of 2 changes.")
    }

    @Test func aStopBeforeAnythingRanSaysSo() {
        let outcome = DeploymentOutcome.from(steps: [(.codex, .notRun), (.claude, .notRun)], finishedAt: finishedAt)
        #expect(outcome.summary == "Stopped before anything was installed.")
        #expect(outcome.failed.isEmpty)
    }

    /// "Did not take it" names only apps that refused, never one the install
    /// never asked.
    @Test func onlyAnAppThatRefusedDidNotTakeIt() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .failed("codex: no")), (.claude, .notRun), (.claude, .notRun)], finishedAt: finishedAt)
        #expect(outcome.failed == [.codex: "codex: no"])
        #expect(outcome.unfinished == [.claude])
        #expect(outcome.summary == "Nothing was installed. One app did not take it.")
    }

    /// With some changes in but no app holding all of its own, the changes
    /// are counted, so the result never contradicts its receipt line.
    @Test func changesInWithNoAppCompleteAreCounted() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.codex, .failed("no")), (.claude, .failed("no")), (.claude, .succeeded)],
            finishedAt: finishedAt)
        #expect(outcome.installed.isEmpty)
        #expect(outcome.summary == "Installed 2 of 4 changes.")
        #expect(outcome.receiptLine.hasPrefix("Installed 2 changes · "))
    }

    /// An app that refused and one never asked both stand outside the apps
    /// installed to.
    @Test func appsThatRefusedOrWereNeverAskedCountAgainstTheApps() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.claude, .failed("no")), (.gemini, .notRun)], finishedAt: finishedAt)
        #expect(outcome.summary == "Installed to 1 of 3 apps.")
    }

    /// The apps are listed as every Launchpad list is, whatever the locale:
    /// "A, B and C".
    @Test func threeAppsAreListedTheLaunchpadWay() {
        let outcome = DeploymentOutcome.from(
            steps: [(.codex, .succeeded), (.claude, .succeeded), (.gemini, .succeeded)], finishedAt: finishedAt)
        #expect(outcome.isComplete)
        #expect(outcome.summary == "Installed to Claude Code, Codex and Gemini CLI.")
    }

    @Test func aFailureWithNoWordsSaysWhichApp() {
        let outcome = DeploymentOutcome.from(steps: [(.codex, .failed(""))], finishedAt: finishedAt)
        #expect(outcome.failed == [.codex: "Codex did not finish this step."])
        #expect(outcome.summary == "Nothing was installed. One app did not take it.")
    }

    @Test func nothingToRunInstallsNothing() {
        let outcome = DeploymentOutcome.from(steps: [], finishedAt: finishedAt)
        #expect(outcome.installed.isEmpty)
        #expect(outcome.isComplete)
        #expect(outcome.summary == "Nothing was installed.")
    }

    @Test func theStepsLeftAloneTravelWithTheOutcome() {
        let left = WorkspaceDeploymentInstallKey(artifactID: ArtifactID(), physicalDestinationID: WorkspaceObjectID())
        let outcome = DeploymentOutcome.from(steps: [(.codex, .succeeded)], leftAlone: [left], finishedAt: finishedAt)
        #expect(outcome.leftAlone == [left])
        #expect(outcome.installed == [.codex])
    }

    /// The operations' results, as the shell's own install reads them: a
    /// failure in one app's operation is that app's.
    @Test func fromTheSessionsResultsAFailureIsTheAppsItHappenedIn() {
        let results = [
            WorkspaceDeploymentSession.Result(
                title: "Install 1 tool in Codex", surfaces: [.codexCLI], succeeded: 1, failed: 0, outputs: []),
            WorkspaceDeploymentSession.Result(
                title: "Set up 1 connection in Claude Code", surfaces: [.claudeCode], succeeded: 0, failed: 1, outputs: ["No."]),
        ]
        let outcome = DeploymentOutcome.from(results: results, leftAlone: [], finishedAt: finishedAt)
        #expect(outcome.installed == [.codex])
        #expect(outcome.failed == [.claude: "No."])
        #expect(outcome.succeededSteps == 1)
        #expect(outcome.failedSteps == 1)
    }
}

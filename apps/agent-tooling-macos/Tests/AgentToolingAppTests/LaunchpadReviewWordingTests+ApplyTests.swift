import Foundation
import Testing

@testable import AgentToolingApp

/// Once a reviewed step takes something out of an app (Agent Tooling's own
/// connection, unticked on Let your apps ask), the review's title says Apply
/// (`PlanReviewLabels`), and so do its progress, its result, its receipt and
/// Done: nothing calls a removal an install (NEW copy, owner flag O6).
@Suite("Launchpad wording · applying a removal")
struct LaunchpadReviewApplyWordingTests {
    private typealias Copy = LaunchpadCopy.Review

    @Test func theProgressSaysApplying() {
        #expect(Copy.installing(1, of: 2, hasRemoval: true) == "Applying 1 of 2…")
        #expect(Copy.installingSpoken(1, of: 2, hasRemoval: true) == "Applying 1 of 2.")
        #expect(Copy.installing(2, of: 4) == "Installing 2 of 4…", "an install says what it always said")
    }

    @Test func theResultAndTheReceiptSayApplied() {
        #expect(Copy.installed(to: "Claude Code", hasRemoval: true) == "Applied to Claude Code.")
        #expect(Copy.installed(1, of: 2, hasRemoval: true) == "Applied to 1 of 2 apps.")
        #expect(Copy.installedChanges(1, of: 3, hasRemoval: true) == "Applied 1 of 3 changes.")
        #expect(Copy.nothingInstalled(hasRemoval: true) == "Nothing was changed.")
        #expect(Copy.nothingInstalled(appsRefusing: 1, hasRemoval: true) == "Nothing was changed. One app did not take it.")
        #expect(Copy.stoppedBeforeAnything(hasRemoval: true) == "Stopped before anything was changed.")
        #expect(Copy.receipt(changes: 1, at: "9:52 AM", hasRemoval: true) == "Applied 1 change · 9:52 AM")
        #expect(Copy.installed(to: "Claude Code") == "Installed to Claude Code.")
    }

    @Test func anOutcomeWithARemovalIsSaidAsApplied() {
        let at = Date(timeIntervalSince1970: 1_792_230_000)
        var outcome = DeploymentOutcome(installed: [.claude], succeededSteps: 1, finishedAt: at)
        #expect(outcome.summary == "Installed to Claude Code.")
        outcome.hasRemoval = true
        #expect(outcome.summary == "Applied to Claude Code.")
        #expect(outcome.receiptLine.hasPrefix("Applied 1 change · "))
        var stopped = DeploymentOutcome(installed: [], unfinished: [.claude], succeededSteps: 0, stoppedSteps: 1, finishedAt: at)
        stopped.hasRemoval = true
        #expect(stopped.summary == "Stopped before anything was changed.")
    }

    @Test func doneSaysApplied() {
        #expect(LaunchpadCopy.Done.installed(changes: 1, apps: 1, hasRemoval: true) == "1 change applied in 1 app")
        #expect(LaunchpadCopy.Done.installed(changes: 2, hasRemoval: true) == "2 changes applied")
        #expect(LaunchpadCopy.Done.nothingInstalled(hasRemoval: true) == "Nothing was changed")
        #expect(LaunchpadCopy.Done.installed(changes: 4, apps: 2) == "4 changes installed in 2 apps")
    }
}

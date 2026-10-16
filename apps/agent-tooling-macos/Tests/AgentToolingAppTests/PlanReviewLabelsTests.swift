import Testing

@testable import AgentToolingApp

/// Pins the plan button and title wording for every mix of steps. The bug
/// these guard against: a plan that only removes read "Install 1 change",
/// because the verb was always "Install". A removal now reads "Apply".
@Suite("Plan review labels")
struct PlanReviewLabelsTests {
    @Test("A plan with no removals installs")
    func installsWithoutRemovals() {
        #expect(PlanReviewLabels.actionLabel(listedCount: 1, runnableCount: 1, hasRemoval: false) == "Install 1 change")
        #expect(PlanReviewLabels.actionLabel(listedCount: 3, runnableCount: 3, hasRemoval: false) == "Install 3 changes")
    }

    @Test("A plan that removes anything applies instead of installing")
    func appliesWhenRemoving() {
        // The old behaviour said "Install 1 change" here; this is the fix.
        #expect(PlanReviewLabels.actionLabel(listedCount: 1, runnableCount: 1, hasRemoval: true) == "Apply 1 change")
        #expect(PlanReviewLabels.actionLabel(listedCount: 5, runnableCount: 2, hasRemoval: true) == "Apply 2 changes")
    }

    @Test("The runnable count, not the listed count, is what the verb counts")
    func countsRunnableSteps() {
        #expect(PlanReviewLabels.actionLabel(listedCount: 4, runnableCount: 1, hasRemoval: false) == "Install 1 change")
    }

    @Test("Nothing to run keeps its own wording regardless of the verb")
    func emptyAndBlockedWording() {
        #expect(PlanReviewLabels.actionLabel(listedCount: 0, runnableCount: 0, hasRemoval: false) == "Nothing to install")
        #expect(PlanReviewLabels.actionLabel(listedCount: 0, runnableCount: 0, hasRemoval: true) == "Nothing to install")
        #expect(PlanReviewLabels.actionLabel(listedCount: 2, runnableCount: 0, hasRemoval: true) == "Nothing can run yet")
    }

    @Test("The title matches the button once there is something to run")
    func titleMatchesButton() {
        #expect(
            PlanReviewLabels.title(listedCount: 1, runnableCount: 1, hasRemoval: true, hasExclusions: false)
                == "Apply 1 change")
        #expect(
            PlanReviewLabels.title(listedCount: 2, runnableCount: 2, hasRemoval: false, hasExclusions: true)
                == "Install 2 changes")
    }

    @Test("An empty plan explains why it is empty")
    func titleWhenEmpty() {
        #expect(
            PlanReviewLabels.title(listedCount: 0, runnableCount: 0, hasRemoval: false, hasExclusions: false)
                == "Nothing to install")
        #expect(
            PlanReviewLabels.title(listedCount: 0, runnableCount: 0, hasRemoval: false, hasExclusions: true)
                == "Nothing can be installed right now")
    }

    /// Home's card, the line under Apps' title and each app's tile count what
    /// a plan is holding. They counted a removal as something "ready to
    /// install"; they now use the plan's one verb.
    @Test("What counts a waiting plan uses the plan's verb")
    func waitingWordingFollowsTheVerb() {
        #expect(PlanReviewLabels.readyTitle(hasRemoval: false) == "Ready to install")
        #expect(PlanReviewLabels.readyTitle(hasRemoval: true) == "Ready to apply")
        #expect(PlanReviewLabels.readyLine(count: 3, hasRemoval: false) == "3 changes ready to install")
        #expect(PlanReviewLabels.readyLine(count: 1, hasRemoval: false) == "1 change ready to install")
        #expect(PlanReviewLabels.readyLine(count: 2, hasRemoval: true) == "2 changes ready to apply")
        #expect(PlanReviewLabels.waitingCount(2, hasRemoval: false) == "2 to install")
        #expect(PlanReviewLabels.waitingCount(1, hasRemoval: true) == "1 to apply")
    }

    @Test("A plan that stops or runs says what kind of plan it is")
    func failureAndProgressFollowTheVerb() {
        #expect(PlanReviewLabels.nothingDoneTitle(hasRemoval: false) == "Nothing was installed")
        #expect(PlanReviewLabels.nothingDoneTitle(hasRemoval: true) == "Nothing was changed")
        #expect(PlanReviewLabels.runningLabel(hasRemoval: false) == "Installing")
        #expect(PlanReviewLabels.runningLabel(hasRemoval: true) == "Applying changes")
    }

    @Test("No wording for a plan that removes calls it an install")
    func removalIsNeverAnInstall() {
        let wording = [
            PlanReviewLabels.verb(hasRemoval: true),
            PlanReviewLabels.actionLabel(listedCount: 2, runnableCount: 2, hasRemoval: true),
            PlanReviewLabels.title(listedCount: 2, runnableCount: 2, hasRemoval: true, hasExclusions: true),
            PlanReviewLabels.nothingDoneTitle(hasRemoval: true),
            PlanReviewLabels.runningLabel(hasRemoval: true),
            PlanReviewLabels.readyTitle(hasRemoval: true),
            PlanReviewLabels.readyLine(count: 2, hasRemoval: true),
            PlanReviewLabels.waitingCount(2, hasRemoval: true),
        ]
        for text in wording {
            #expect(!text.localizedCaseInsensitiveContains("install"), "\(text) calls a removal an install")
        }
    }
}

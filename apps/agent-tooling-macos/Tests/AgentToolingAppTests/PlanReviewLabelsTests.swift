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
}

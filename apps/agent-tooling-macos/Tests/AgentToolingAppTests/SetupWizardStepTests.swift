import Testing

@testable import AgentToolingApp

/// What the setup wizard says at its last stop.
@Suite("Setup wizard steps")
struct SetupWizardStepTests {
    /// The done step counts what is left, and the sentence after the count
    /// agrees with it: one item "stays", several "stay".
    @Test func theDoneStepAgreesWithWhatIsLeft() {
        #expect(SetupWizardStep.leftOver(0) == "Nothing is left to look at.")
        #expect(SetupWizardStep.leftOver(1) == "1 item left. It stays on the Checkup tab.")
        #expect(SetupWizardStep.leftOver(4) == "4 items left. They stay on the Checkup tab.")
    }
}

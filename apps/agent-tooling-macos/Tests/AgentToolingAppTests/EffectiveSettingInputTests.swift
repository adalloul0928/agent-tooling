import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// What the App settings edit sheet offers for a new value, and what it would
/// write. A setting with a fixed set of values is chosen, never typed; a value
/// the app already holds is never dropped or replaced just by opening the
/// sheet; and a number field writes only a number.
@Suite("Effective setting input")
struct EffectiveSettingInputTests {
    private let modes: [ConfigurationValue] = [.string("untrusted"), .string("on-request"), .string("never")]

    @Test func aSettingThatIsOnOrOffIsSwitched() {
        let input = EffectiveSettingInput(current: .boolean(true), choices: [])
        #expect(input == .toggle)
        #expect(input.change(from: .boolean(true), text: "", flag: true, choice: nil) == nil)
        #expect(input.change(from: .boolean(true), text: "", flag: false, choice: nil) == .boolean(false))
    }

    /// The defect: a constrained setting was a free text field, so any string,
    /// an invalid one included, could be written.
    @Test func aSettingWithDefinedValuesIsChosenFromThem() {
        let input = EffectiveSettingInput(current: .string("on-request"), choices: modes)
        #expect(input == .choice(options: modes, unlisted: nil))
        #expect(input.change(from: .string("on-request"), text: "", flag: false, choice: .string("never")) == .string("never"))
        #expect(input.change(from: .string("on-request"), text: "", flag: false, choice: .string("on-request")) == nil)
        #expect(input.change(from: .string("on-request"), text: "", flag: false, choice: nil) == nil)
    }

    /// A value the app does not define stays on offer, and staying on it is no
    /// change, so the sheet cannot rewrite it just by being opened and saved.
    @Test func aCurrentValueOutsideTheSetIsKeptRatherThanDropped() {
        let input = EffectiveSettingInput(current: .string("auto"), choices: modes)
        #expect(input == .choice(options: modes, unlisted: .string("auto")))
        #expect(input.change(from: .string("auto"), text: "", flag: false, choice: .string("auto")) == nil)
        #expect(input.change(from: .string("auto"), text: "", flag: false, choice: .string("never")) == .string("never"))
    }

    /// Text that is not a number used to be written as a string into a number
    /// setting, and "nan" or "inf" reached the JSON writer, which cannot encode
    /// them.
    @Test func aNumberIsTypedAndOnlyAFiniteNumberIsWritten() {
        let input = EffectiveSettingInput(current: .number(30), choices: [])
        #expect(input == .number)
        #expect(input.change(from: .number(30), text: "30", flag: false, choice: nil) == nil)
        #expect(input.change(from: .number(30), text: " 7 ", flag: false, choice: nil) == .number(7))
        for typed in ["", "thirty", "nan", "inf", "-inf"] {
            #expect(input.value(text: typed, flag: false, choice: nil) == nil, "\(typed)")
        }
    }

    @Test func anOpenEndedValueIsTyped() {
        let input = EffectiveSettingInput(current: .string("opus"), choices: [])
        #expect(input == .text)
        #expect(input.change(from: .string("opus"), text: "opus", flag: false, choice: nil) == nil)
        #expect(input.change(from: .string("opus"), text: "", flag: false, choice: nil) == nil)
        #expect(input.change(from: .string("opus"), text: "sonnet", flag: false, choice: nil) == .string("sonnet"))
    }

    /// The sheet draws its picker, with a current value outside the set,
    /// rather than failing or laying out to nothing.
    @Test @MainActor func theSheetDrawsAChoice() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let edit = WorkspaceSettingsSession.PendingEdit(
            surface: .claudeCode, surfaceTitle: "Claude Code",
            row: EffectiveConfigurationRow(
                key: "approvalMode", displayName: "Approval mode", value: .string("auto"),
                definedBy: .user, definingSourcePath: nil, contributions: [], rule: .replace,
                writableLayer: .user, requiresNewSession: true),
            layer: .user, sourcePath: "/Users/example/.claude/settings.json", fingerprint: nil)

        try expectDrawn(
            EffectiveSettingEditSheet(session: fixture.workspace.settings, edit: edit, choices: modes),
            size: SheetSize.medium)
    }
}

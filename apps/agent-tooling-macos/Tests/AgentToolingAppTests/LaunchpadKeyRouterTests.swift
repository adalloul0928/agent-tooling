import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The stage's key decisions: whether a press is a fresh one (D25), which
/// layer ⎋ reaches, what ↩ and ⌘↩ do where only ⌘↩ acts, and the keycaps a
/// shortcut draws.
@Suite("Launchpad keys")
@MainActor
struct LaunchpadKeyRouterTests {
    // MARK: - D25

    /// AppKit raises an exception when a mouse event is asked whether it
    /// repeats. A click on a primary must read as a fresh press, not crash.
    @Test func aClickIsNeverARepeatAndDoesNotCrash() throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown] {
            let click = try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(!LaunchpadKeyRouter.isRepeatKeyEvent(click))
        }
        let other = try #require(
            NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0))
        #expect(!LaunchpadKeyRouter.isRepeatKeyEvent(other))
        #expect(!LaunchpadKeyRouter.isRepeatKeyEvent(nil))
    }

    @Test func aHeldKeyIsARepeatAndAFreshPressIsNot() throws {
        #expect(LaunchpadKeyRouter.isRepeatKeyEvent(try Self.returnKey(.keyDown, repeating: true)))
        #expect(LaunchpadKeyRouter.isRepeatKeyEvent(try Self.returnKey(.keyUp, repeating: true)))
        #expect(!LaunchpadKeyRouter.isRepeatKeyEvent(try Self.returnKey(.keyDown, repeating: false)))
        #expect(!LaunchpadKeyRouter.isRepeatKeyEvent(try Self.returnKey(.keyUp, repeating: false)))
    }

    // MARK: - ⌘↩

    /// A plain ↩ where only ⌘↩ acts writes nothing: it asks for ⌘↩.
    @Test func aPlainReturnOnACommandReturnScreenAsksForCommandReturn() {
        #expect(LaunchpadKeyRouter.commandReturn(withCommand: false, isRepeat: false, isReady: true) == .hint)
        #expect(LaunchpadKeyRouter.commandReturn(withCommand: false, isRepeat: false, isReady: false) == .hint)
        #expect(LaunchpadKeyRouter.commandReturn(withCommand: false, isRepeat: true, isReady: true) == .hint)
    }

    @Test func commandReturnActsOnlyOnAFreshPressOnceReady() {
        #expect(LaunchpadKeyRouter.commandReturn(withCommand: true, isRepeat: false, isReady: true) == .perform)
        #expect(LaunchpadKeyRouter.commandReturn(withCommand: true, isRepeat: true, isReady: true) == .ignore)
        #expect(LaunchpadKeyRouter.commandReturn(withCommand: true, isRepeat: false, isReady: false) == .ignore)
    }

    // MARK: - ⎋

    @Test func escapeReachesTheTopLayerFirst() {
        typealias State = LaunchpadKeyRouter.EscapeState
        let cases: [(State, LaunchpadKeyRouter.EscapeAction)] = [
            (State(popoverOpen: true, confirmingLeave: true, reviewPresented: true), .closePopover),
            (State(confirmingLeave: true, reviewPresented: true), .keepGoing),
            (State(reviewPresented: true, later: .stop), .cancelReview),
            (State(reviewPresented: true, reviewBusy: true), .ignore),
            (State(later: .setUpLater), .confirmLeave),
            (State(later: .stop), .stop),
            (State(later: .none), .ignore),
        ]
        for (state, action) in cases {
            #expect(LaunchpadKeyRouter.escape(state) == action, "\(state)")
        }
    }

    /// D31: nothing answers ⎋ while something is finishing, not even an open
    /// popover.
    @Test func escapeDoesNothingWhileSomethingFinishes() {
        let state = LaunchpadKeyRouter.EscapeState(
            popoverOpen: true, confirmingLeave: true, reviewPresented: true, later: .stop, finishing: true)
        #expect(LaunchpadKeyRouter.escape(state) == .ignore)
    }

    // MARK: - Keycaps

    @Test func aShortcutDrawsExactlyItsKeys() {
        #expect(KeyCombo.keys(of: .defaultAction) == [.returnKey])
        #expect(KeyCombo.keys(of: .cancelAction) == [.escape])
        #expect(KeyCombo.keys(of: KeyboardShortcut(.return, modifiers: .command)) == [.command, .returnKey])
        #expect(KeyCombo.keys(of: KeyboardShortcut("[", modifiers: .command)) == [.command, .character("[")])
        // Modifiers in the order macOS menus draw them.
        #expect(
            KeyCombo.keys(of: KeyboardShortcut("k", modifiers: [.command, .shift, .option, .control])) == [
                .control, .option, .shift, .command, .character("K"),
            ])
    }

    @Test func aShortcutIsSpokenByItsKeysNames() {
        #expect(KeyCombo.spoken(KeyboardShortcut(.return, modifiers: .command)) == "Command-Return")
        #expect(KeyCombo.spoken(.cancelAction) == "Escape")
        #expect(LaunchpadCopy.Footer.commandReturnSpoken.contains(KeyCombo.spoken(KeyboardShortcut(.return, modifiers: .command))))
        #expect(
            LaunchpadCopy.Footer.commandReturnAccessibilityHint.hasPrefix(
                KeyCombo.spoken(KeyboardShortcut(.return, modifiers: .command))))
    }

    // MARK: - Helpers

    private static func returnKey(_ type: NSEvent.EventType, repeating: Bool) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: 36))
    }
}

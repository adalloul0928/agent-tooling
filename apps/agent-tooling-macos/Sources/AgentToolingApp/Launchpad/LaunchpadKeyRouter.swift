import AppKit

/// The stage's key decisions, as pure functions a test can walk: which layer
/// ⎋ reaches, whether a press is a fresh one, and what ↩ and ⌘↩ do on a
/// screen where only ⌘↩ acts.
///
/// The keys themselves are bound on the buttons that own them, so the
/// shortcut VoiceOver exposes is the one that works; these functions decide
/// what a bound key does once it fires.
@MainActor
enum LaunchpadKeyRouter {
    /// Whether the event being handled is a key held down and repeating.
    ///
    /// A held ↩ must not race through screens, and a held ⌘↩ must not
    /// install twice. Only a key event can repeat: AppKit raises an exception
    /// when a mouse event is asked whether it repeats, and a click on a
    /// primary is never a repeat, so anything but a key down or key up reads
    /// as a fresh press.
    static func isRepeatKeyEvent(_ event: NSEvent? = NSApp?.currentEvent) -> Bool {
        guard let event, event.type == .keyDown || event.type == .keyUp else { return false }
        return event.isARepeat
    }

    /// What ⎋ reaches, from the top layer down.
    enum EscapeAction: Equatable {
        /// A popover or chooser closes itself.
        case closePopover
        /// FooterConfirm's Keep going.
        case keepGoing
        /// The review panel's Cancel.
        case cancelReview
        /// The footer's Stop: the read or the join stops, keeping nothing.
        case stop
        /// The footer's Set up later: FooterConfirm appears.
        case confirmLeave
        /// Nothing happens: something is finishing, or there is no later slot.
        case ignore
    }

    /// The footer's later slot, as the escape decision needs it.
    enum LaterSlot: Equatable {
        case setUpLater
        case stop
        case none
    }

    /// The state ⎋ is decided over.
    struct EscapeState: Equatable {
        var popoverOpen = false
        var confirmingLeave = false
        var reviewPresented = false
        /// The review is installing: its Cancel does nothing until it ends.
        var reviewBusy = false
        var later = LaterSlot.setUpLater
        /// Something is past the point where stopping would leave half a
        /// change. ⎋ does nothing then.
        var finishing = false
    }

    /// ⎋, layered: a popover first, then FooterConfirm, then the review
    /// panel, then the footer's later slot. Nothing while finishing.
    static func escape(_ state: EscapeState) -> EscapeAction {
        if state.finishing { return .ignore }
        if state.popoverOpen { return .closePopover }
        if state.confirmingLeave { return .keepGoing }
        if state.reviewPresented { return state.reviewBusy ? .ignore : .cancelReview }
        switch state.later {
        case .setUpLater: return .confirmLeave
        case .stop: return .stop
        case .none: return .ignore
        }
    }

    /// What a press on a screen where only ⌘↩ acts does.
    enum CommandReturnAction: Equatable {
        /// ⌘↩, fresh, while the action is ready: it runs.
        case perform
        /// A plain ↩: nothing is written; the keycaps flash and the hint
        /// says to press ⌘↩.
        case hint
        /// A repeat, or ⌘↩ before the action is ready: nothing.
        case ignore
    }

    static func commandReturn(withCommand: Bool, isRepeat: Bool, isReady: Bool) -> CommandReturnAction {
        guard withCommand else { return .hint }
        return !isRepeat && isReady ? .perform : .ignore
    }
}

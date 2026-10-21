import AgentToolingCore
import Foundation

/// One screen of the setup stage. The raw value is the cursor setup records,
/// so a case is renamed never, and added only at the end.
enum LaunchpadStep: String, Codable, CaseIterable, Sendable {
    /// Before you start: move Agent Tooling to Applications (S00).
    case move
    /// Welcome: start a library here or join one (S01).
    case welcome
    /// Your apps: which apps this Mac manages (S02, V01).
    case apps
    /// What Agent Tooling reads, then the read itself (S04, S05).
    case reads
    /// Your library, as read (S06).
    case found
    /// Make skills yours and add from the catalogs (S08).
    case library
    /// Put tools in apps (S10).
    case place
    /// Let your apps ask Agent Tooling (S11).
    case ask
    /// Let your assistant help (S15).
    case assistant
    /// How Agent Tooling behaves (S16).
    case behave
    /// Your other Macs (S17).
    case macs
    /// Done (S22).
    case done
    /// Join your library from another Mac (J01, V08).
    case join
    /// You joined: what arrived from the other Macs (J02).
    case arrivals
}

/// Which walk a setup is on. A revisit is an entry, not a path: it opens one
/// step of whichever path the record was made on.
enum LaunchpadPath: String, Codable, Sendable {
    /// A first Mac starting its own library.
    case startHere
    /// A second Mac joining the library another Mac shares.
    case join
    /// Set up this Mac… again, on a Mac that already has its library.
    case rerun
}

/// Where the stage opens, and why.
enum SetupEntry: Equatable, Sendable {
    /// A Mac with no library: Before you start, or Welcome.
    case firstRun
    /// A first run that had passed its commit point and never handed off,
    /// reopened at its cursor at launch.
    case continueFirstRun(LaunchpadStep)
    /// A join that created its store but stopped before its locator record,
    /// reopened in Join's Finish joining state.
    case finishJoin(WorkspaceObjectID)
    /// Home's Resume row: a first run that was left for later.
    case resume(LaunchpadStep)
    /// Set up this Mac… on a Mac that already has its library: Your apps,
    /// with no fork.
    case rerun
    /// One step on its own, from one of Home's rows. Its primary hands off.
    case revisit(LaunchpadStep)
}

/// What a step change crossfades as. The apps, the read and what was found are
/// one persistent view, so its tiles never move between them; every other
/// step is its own.
enum LaunchpadTransitionGroup: Hashable, Sendable {
    case tiles
    case single(LaunchpadStep)
}

/// The facts the transition table reads, gathered from the flow, so the table
/// itself stays a pure function a test can walk.
struct LaunchpadTransitionContext: Equatable, Sendable {
    /// The apps this Mac manages, as chosen on Your apps or recorded since.
    var managed: Set<ClientKind> = []
    /// The apps a read has observed on this Mac.
    var observed: Set<ClientKind> = []
    /// There is nothing to read, place or connect: the library was created
    /// with no apps at all (V01's Continue without apps), or, on a rerun, no
    /// app is turned on.
    var startedEmpty = false
    /// Claude Code or Codex is managed, so an assistant can run.
    var managesAssistant = false
    /// This Mac already syncs with a repository.
    var hasEnrollment = false
}

/// Whether the work a step has under way may be stopped right now.
enum LaunchpadInterruption: Equatable, Sendable {
    /// Nothing is running.
    case idle
    /// Running, and stopping it keeps nothing: a read, a join before it
    /// registers.
    case stoppable
    /// Past the point where stopping would leave half a change: the commit,
    /// a join after its store exists, an install's current step, a publish.
    /// It is waited out, never cut short; the sentence says what is running.
    case finishing(String)
}

/// A model that outlives its screen and may have work under way when the
/// person quits or closes the stage. The flow asks every one it holds.
@MainActor
protocol LaunchpadInterruptible: AnyObject {
    var interruption: LaunchpadInterruption { get }
    /// Stops what can be stopped, keeping nothing, and returns once nothing
    /// is running. A finishing window is waited out, not cut short.
    func interrupt() async
}

// MARK: - The registry

/// What the stage shows around a step: the footer's step name and capsules,
/// where Back goes, and whether the step is past the commit point.
struct LaunchpadStepInfo: Equatable, Sendable {
    /// How far along the path's capsules a step is: reached of total.
    struct Capsules: Equatable, Sendable {
        let reached: Int
        let total: Int
    }

    let step: LaunchpadStep
    /// The footer's step name: the capsule's name, not the screen's title.
    let footerName: String
    /// Nil on the screens before a path is chosen, and on a revisit.
    let capsules: Capsules?
    /// Where ⌘[ goes, or nil where there is no Back.
    let back: LaunchpadStep?
    /// Whether the step is past the commit point: the library exists.
    let isPostCommit: Bool
    let group: LaunchpadTransitionGroup

    /// The registry: one row per step, path and entry.
    static func of(
        _ step: LaunchpadStep, path: LaunchpadPath?, entry: SetupEntry,
        context: LaunchpadTransitionContext = LaunchpadTransitionContext(), isDetour: Bool = false
    ) -> LaunchpadStepInfo {
        let isRevisit = if case .revisit = entry { true } else { false }
        return LaunchpadStepInfo(
            step: step,
            footerName: footerName(step, path: path, isDetour: isDetour),
            capsules: isRevisit ? nil : capsules(step, path: path, isDetour: isDetour),
            back: isRevisit ? nil : LaunchpadStep.back(from: step, path: path, context: context, isDetour: isDetour),
            isPostCommit: step.isPostCommit,
            group: step.transitionGroup)
    }

    private static func footerName(_ step: LaunchpadStep, path: LaunchpadPath?, isDetour: Bool) -> String {
        let copy = LaunchpadCopy.Footer.self
        switch step {
        case .move: return copy.stepBeforeYouStart
        case .welcome: return copy.stepWelcome
        case .apps, .reads: return copy.stepYourApps
        case .found, .library: return copy.stepYourLibrary
        case .place: return copy.stepPutInApps
        case .ask: return isDetour ? copy.stepArrivals : copy.stepPutInApps
        case .assistant, .behave: return path == .join ? copy.stepThisMac : copy.stepPreferences
        case .macs: return copy.stepOtherMacs
        case .done: return copy.stepDone
        case .join: return copy.stepJoin
        case .arrivals: return copy.stepArrivals
        }
    }

    private static func capsules(_ step: LaunchpadStep, path: LaunchpadPath?, isDetour: Bool) -> Capsules? {
        if path == .join {
            let total = LaunchpadStep.joinCapsules
            switch step {
            case .join: return Capsules(reached: 1, total: total)
            case .arrivals: return Capsules(reached: 2, total: total)
            case .ask: return isDetour ? Capsules(reached: 2, total: total) : nil
            case .assistant, .behave, .done: return Capsules(reached: 3, total: total)
            default: return nil
            }
        }
        let total = LaunchpadStep.startHereCapsules
        switch step {
        case .move, .welcome, .join, .arrivals: return nil
        case .apps, .reads: return Capsules(reached: 1, total: total)
        case .found, .library: return Capsules(reached: 2, total: total)
        case .place, .ask: return Capsules(reached: 3, total: total)
        case .assistant, .behave: return Capsules(reached: 4, total: total)
        case .macs, .done: return Capsules(reached: 5, total: total)
        }
    }
}

// MARK: - The transition table

extension LaunchpadStep {
    /// Start here's five capsules (Your apps · Your library · Put in apps ·
    /// Preferences · Other Macs) and Join's three (Join · Arrivals · This
    /// Mac).
    static let startHereCapsules = 5
    static let joinCapsules = 3

    /// Whether the library exists by the time this step shows.
    var isPostCommit: Bool {
        switch self {
        case .move, .welcome, .apps, .reads, .join: false
        case .found, .library, .place, .ask, .assistant, .behave, .macs, .done, .arrivals: true
        }
    }

    var transitionGroup: LaunchpadTransitionGroup {
        switch self {
        case .apps, .reads, .found: .tiles
        default: .single(self)
        }
    }

    /// Every step a path can show, in order. A step the context skips is
    /// passed over; Before you start comes before Welcome only as an entry.
    static func sequence(for path: LaunchpadPath) -> [LaunchpadStep] {
        switch path {
        case .startHere: [.welcome, .apps, .reads, .found, .library, .place, .ask, .assistant, .behave, .macs, .done]
        case .join: [.welcome, .join, .arrivals, .assistant, .behave, .done]
        case .rerun: [.apps, .reads, .found, .library, .place, .ask, .assistant, .behave, .macs, .done]
        }
    }

    /// Whether `step` is passed over on `path`, given what the flow knows.
    ///
    /// A library started with no apps (V01), or a rerun with none turned on,
    /// has nothing to read, place or connect; with no app managed there is
    /// nothing to place or connect; and with neither Claude Code nor Codex
    /// managed no assistant can run.
    static func isSkipped(_ step: LaunchpadStep, path: LaunchpadPath, context: LaunchpadTransitionContext) -> Bool {
        switch step {
        case .reads, .found: path != .join && context.startedEmpty
        case .place, .ask: path != .join && (context.startedEmpty || context.managed.isEmpty)
        case .assistant: !context.managesAssistant
        default: false
        }
    }

    /// The step after `step` on `path`, or nil at the end. Welcome's next
    /// depends on the fork, so it is nil until a path is chosen.
    static func next(after step: LaunchpadStep, path: LaunchpadPath?, context: LaunchpadTransitionContext) -> LaunchpadStep? {
        if step == .move { return .welcome }
        guard let path else { return nil }
        let order = sequence(for: path)
        guard let index = order.firstIndex(of: step) else { return nil }
        return order[(index + 1)...].first { !isSkipped($0, path: path, context: context) }
    }

    /// Where ⌘[ goes from `step`, or nil where there is no Back.
    ///
    /// Before the commit point Back walks the pre-commit steps. The commit
    /// point itself (Your library as read, You joined) and Done have none.
    /// After it, Back goes to the previous step shown that is also past the
    /// commit point, so it never walks back to before the library existed.
    /// On Join's detour, Let your apps ask returns to You joined.
    static func back(
        from step: LaunchpadStep, path: LaunchpadPath?, context: LaunchpadTransitionContext, isDetour: Bool = false
    ) -> LaunchpadStep? {
        switch step {
        case .move, .welcome, .found, .done, .arrivals: return nil
        case .apps: return path == .rerun ? nil : .welcome
        case .reads: return .apps
        case .join: return .welcome
        case .ask where isDetour: return .arrivals
        case .library, .place, .ask, .assistant, .behave, .macs:
            guard let path else { return nil }
            let order = sequence(for: path)
            guard let index = order.firstIndex(of: step) else { return nil }
            for candidate in order[..<index].reversed() where !isSkipped(candidate, path: path, context: context) {
                return candidate.isPostCommit ? candidate : nil
            }
            return nil
        }
    }
}

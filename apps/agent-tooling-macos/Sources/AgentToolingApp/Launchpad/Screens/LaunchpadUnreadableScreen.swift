import AgentToolingCore
import SwiftUI

/// Recovers unreadable workspace records without changing them or creating another
/// library. Actions depend on whether the format is newer, damaged, or inaccessible.
/// Close and ⌘W quit; Escape does nothing because no setup flow exists.
struct LaunchpadUnreadableScreen: View {
    /// What the screen's buttons do.
    struct Actions {
        var quit: @MainActor () -> Void = {}
        /// Shows the support folder in Finder, with the record selected.
        var showInFinder: @MainActor () -> Void = {}
        /// Reads the record again.
        var tryAgain: @MainActor () -> Void = {}
    }

    let reason: AppLaunchState.UnreadableReason
    var actions = Actions()

    var body: some View {
        SetupStage {
            VStack(spacing: 0) {
                // Two shares of the free height above and three below, so the
                // words sit a little above the middle, where the eye puts it.
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                AgentToolingMark(size: Size.heroMark)
                Text(Self.title(for: reason))
                    .font(AgentFont.hero)
                    .lineLimit(1)
                    .frame(height: StageLayout.Header.heroTitleLine)
                    .padding(.top, StageLayout.Unreadable.titleGap)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)
                Text(Self.message(for: reason))
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(StageLayout.Unreadable.messageLines)
                    .wrapsLines()
                    .frame(maxWidth: Size.proseMaxWidth)
                    .padding(.top, StageLayout.Unreadable.messageGap)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } footer: {
            StageFooterBar(info: Self.footerInfo, spec: Self.footer(for: reason, actions: actions))
        } overlay: {
            EmptyView()
        }
    }

    static func title(for reason: AppLaunchState.UnreadableReason) -> String {
        switch reason {
        case .newerFormat: LaunchpadCopy.Unreadable.newerTitle
        case .damaged, .io: LaunchpadCopy.Unreadable.unreadableTitle
        }
    }

    static func message(for reason: AppLaunchState.UnreadableReason) -> String {
        switch reason {
        case .newerFormat: LaunchpadCopy.Unreadable.Failures.newerFormat
        case .damaged: LaunchpadCopy.Unreadable.Failures.damaged
        case .io(let detail): LaunchpadCopy.Unreadable.Failures.unreadable(detail)
        }
    }

    /// The footer: Quit Agent Tooling ↩, with Show in Finder beside it for a
    /// damaged record; Try again ↩, with Quit Agent Tooling beside it, when
    /// the disk would not read. No later slot: there is no walk to leave.
    static func footer(for reason: AppLaunchState.UnreadableReason, actions: Actions) -> StageFooterSpec {
        let copy = LaunchpadCopy.Unreadable.self
        switch reason {
        case .newerFormat:
            return StageFooterSpec(later: .none, showsBack: false, primary: .init(title: copy.quit, action: actions.quit))
        case .damaged:
            return StageFooterSpec(
                later: .none, showsBack: false, secondary: .init(title: copy.showInFinder, action: actions.showInFinder),
                primary: .init(title: copy.quit, action: actions.quit))
        case .io:
            return StageFooterSpec(
                later: .none, showsBack: false, secondary: .init(title: copy.quit, action: actions.quit),
                primary: .init(title: copy.tryAgain, action: actions.tryAgain))
        }
    }

    /// The footer's left side: no step, no capsules, no Back.
    private static let footerInfo = LaunchpadStepInfo(
        step: .welcome, footerName: "", capsules: nil, back: nil, isPostCommit: false, group: .single(.welcome))
}

extension StageLayout {
    /// The unreadable screen: the mark, the title under it, the words under
    /// that, centred a little above the middle of the content slot.
    enum Unreadable {
        /// From the mark to the title.
        static let titleGap: CGFloat = Space.xxxl
        /// From the title to the words.
        static let messageGap: CGFloat = Space.md
        /// The most lines the words take before they truncate.
        static let messageLines = 3
    }
}

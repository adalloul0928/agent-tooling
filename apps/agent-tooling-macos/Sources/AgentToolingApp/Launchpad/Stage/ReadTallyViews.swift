import SwiftUI

/// What the read has read, as one caption: "11 of 14 places read · 7 of 9
/// commands run · 0 changed in your apps" while it reads, "14 places read · 9
/// commands run · 0 changed in your apps" once it has.
///
/// The figures are tabular and tick as they change, except under Reduce
/// Motion or in a still, where they jump. The last figure is a fact rather
/// than a count, so it never animates. VoiceOver reads the tally once, with
/// its final figures: while the read is under way it is hidden.
struct TallyLine: View {
    let placesRead: Int
    let commandsRun: Int
    /// The list's totals, while the read is under way; nil once it is done.
    var totals: (places: Int, commands: Int)?
    /// What VoiceOver reads, once the figures are final; nil hides it.
    var finalLabel: String?
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let copy = LaunchpadCopy.Reads.self
        let counts =
            totals.map {
                copy.tallyReading(places: placesRead, of: $0.places, commands: commandsRun, of: $0.commands)
            } ?? copy.tallyDone(places: placesRead, commands: commandsRun)
        HStack(spacing: 0) {
            Text(counts)
                .contentTransition(motion.resolved(reduceMotion: reduceMotion).animatesDetails ? .numericText() : .identity)
            Text(copy.tallySeparator + copy.zeroChanged)
                .transaction { $0.animation = nil }
        }
        .font(AgentFont.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(finalLabel ?? "")
        .accessibilityHidden(finalLabel == nil)
    }
}

/// The library's own line beside the tally: what the read leads to, then
/// that it is under way, then that it is done. "Then: create your library",
/// "Creating your library…", "Your library is created"; on a rerun, "Then:
/// update your library" to "Your library is up to date".
///
/// The pending ring and words are secondary, never tertiary, because they
/// carry meaning; once done, the words are in the label colour and the check
/// draws on, except under Reduce Motion or in a still.
struct CommitLine: View {
    enum State: Equatable, Sendable {
        case pending
        case committing
        case done
    }

    let state: State
    /// The library already existed, and the read updates it.
    var updates = false
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var words: String {
        let copy = LaunchpadCopy.Reads.self
        switch state {
        case .pending: return updates ? copy.commitPendingRerun : copy.commitPending
        case .committing: return updates ? LaunchpadCopy.Footer.updatingLibrary : LaunchpadCopy.Footer.creatingLibrary
        case .done: return updates ? copy.commitDoneRerun : copy.commitDone
        }
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            ZStack {
                switch state {
                case .pending:
                    AbsentMark(size: Size.glyphSmall, inset: 0)
                case .committing:
                    ProgressView().controlSize(.mini)
                case .done:
                    if motion.resolved(reduceMotion: reduceMotion).animatesDetails {
                        check.transition(.symbolEffect(.drawOn))
                    } else {
                        check.transition(.opacity)
                    }
                }
            }
            .frame(width: Size.glyphSmall, height: Size.glyphSmall)
            .accessibilityHidden(true)
            Text(words)
                .font(AgentFont.captionMedium)
                .foregroundStyle(state == .done ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var check: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: Size.glyphSmall))
            .foregroundStyle(AgentTheme.ok)
    }
}

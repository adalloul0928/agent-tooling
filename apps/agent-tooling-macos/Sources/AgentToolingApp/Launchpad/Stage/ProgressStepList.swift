import SwiftUI

/// One line of a list of steps that resolve in order: J01's four checks
/// before joining and its five steps while it joins.
struct ProgressStep: Identifiable, Equatable {
    enum State: Equatable, Sendable {
        /// Done: a green check, drawn on as it lands.
        case done
        /// Under way: a spinner, and the words in medium weight.
        case running
        /// Not reached yet: its number in a ring.
        case waiting(Int)
        /// Not checked, because an earlier check stopped the list: a clock,
        /// and "Not checked yet" at the end of the line, since unknown is
        /// never shown as passed or failed.
        case notChecked
        /// Where it stopped: a red cross, the words in the label colour.
        case failed
        /// Words alone, such as "Not started".
        case note
    }

    let id: String
    let title: String
    let state: State
}

/// A list label over 26 pt lines, each led by a 14 pt glyph, as J01 and V08
/// draw their two columns. VoiceOver reads each line with its state.
struct ProgressStepList: View {
    let label: String
    let steps: [ProgressStep]
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            StageListLabel(label)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    row(step)
                        .frame(height: StageLayout.Join.progressRow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func row(_ step: ProgressStep) -> some View {
        HStack(spacing: Space.sm) {
            glyph(step.state)
                .frame(width: Size.glyph, height: Size.glyph)
            Text(step.title)
                .font(step.state == .running ? AgentFont.bodyMedium : AgentFont.body)
                .foregroundStyle(isQuiet(step.state) ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if step.state == .notChecked {
                Spacer(minLength: Space.md)
                Text(LaunchpadCopy.Join.notCheckedYet)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, Space.xxs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(step))
    }

    @ViewBuilder private func glyph(_ state: ProgressStep.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, AgentTheme.ok)
                .font(.system(size: Size.glyph, weight: .medium))
                .transition(drawsOn ? AnyTransition(.symbolEffect(.drawOn)) : .identity)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .waiting(let index):
            Text("\(index)")
                .font(AgentFont.microSemibold)
                .foregroundStyle(.secondary)
                .frame(width: Size.glyph, height: Size.glyph)
                .overlay { Circle().strokeBorder(AbsentRingStyle(), lineWidth: Hairline.width) }
        case .notChecked:
            Image(systemName: "clock")
                .font(.system(size: Size.glyph))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, AgentTheme.failure)
                .font(.system(size: Size.glyph, weight: .medium))
        case .note:
            EmptyView()
        }
    }

    private var drawsOn: Bool { motion.resolved(reduceMotion: reduceMotion).animatesDetails }

    private func isQuiet(_ state: ProgressStep.State) -> Bool {
        switch state {
        case .waiting, .notChecked, .note: true
        case .done, .running, .failed: false
        }
    }

    /// "Git is installed, done", "Checking this Mac’s apps, under way".
    static func spoken(_ step: ProgressStep) -> String {
        let copy = LaunchpadCopy.Join.self
        switch step.state {
        case .done: return copy.stepDone(step.title)
        case .running: return copy.stepRunning(step.title)
        case .waiting: return copy.stepWaiting(step.title)
        case .notChecked: return copy.stepNotChecked(step.title)
        case .failed: return copy.stepFailed(step.title)
        case .note: return step.title
        }
    }
}

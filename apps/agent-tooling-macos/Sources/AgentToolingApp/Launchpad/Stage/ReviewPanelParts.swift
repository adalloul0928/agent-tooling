import AgentToolingCore
import AppKit
import SwiftUI

// The pieces of a reviewed plan, as the stage's review panel and the shared
// review sheet draw it: the library row, the Before you approve line, each
// app's header, and the numbered steps with what they run.

extension StageLayout.ReviewPanel {
    /// One line of a command or path in a step's well: mono at 11 on a 16 pt
    /// line, so a well is 28 tall for one line and 44 for two.
    static let wellLine: CGFloat = 16
    /// The room a well keeps at its trailing edge for its copy button.
    static let wellTrailing: CGFloat = 34
    /// The copy button in a well's corner.
    static let copyButton: CGFloat = 24
    /// A disclosure chevron's glyph.
    static let chevron: CGFloat = 10
    /// How far the Before you approve line may run into the panel's
    /// trailing inset to stay on one line: the inset itself.
    static let safetyOverhang: CGFloat = Space.xxxl
}

/// The library row: what the setup saved in the library, kept apart from what
/// reaches an app, with Space or a click opening its lines in place.
struct ReviewLibraryRow: View {
    let line: String
    let lines: [String]
    let disclosure: (Bool) -> String
    /// What VoiceOver adds after the row's name and value.
    let hint: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: StageLayout.ReviewPanel.chevron, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isExpanded ? .disclosureOpen : .zero)
                    Text(LaunchpadCopy.Review.inYourLibrary)
                        .font(AgentFont.captionSemibold)
                    Text(line)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Space.md)
                    Label {
                        Text(LaunchpadCopy.Review.saved)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AgentTheme.ok)
                    }
                    .labelStyle(.reviewStatus)
                }
                .padding(.horizontal, Space.lg)
                .frame(height: StageLayout.ReviewPanel.libraryRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LaunchpadCopy.Review.inYourLibrary)
            .accessibilityValue(disclosure(isExpanded))
            .accessibilityHint(hint)
            if isExpanded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(AgentFont.caption)
                            .wrapsLines()
                    }
                }
                .padding(.leading, Space.lg + StageLayout.ReviewPanel.chevron + Space.md)
                .padding(.trailing, Space.lg)
                .padding(.bottom, Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .background(AgentTheme.fillSubtle, in: RoundedRectangle.control)
    }
}

/// Before you approve: one neutral line of facts about what runs, never a
/// verdict, so a clean plan reads as calmly as the panel draws it.
///
/// On the stage's panel it keeps to one line, as the fragment sets it,
/// running into the panel's trailing inset when it needs a few points more
/// (`overhang`); a line longer than that wraps inside the column instead, so
/// no word is cut off. The shared sheet gives it no overhang.
struct ReviewSafetyRow: View {
    let text: String
    var overhang: CGFloat = StageLayout.ReviewPanel.safetyOverhang

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row.fixedSize(horizontal: true, vertical: false)
            row.padding(.trailing, overhang)
        }
        .padding(.trailing, -overhang)
        .frame(minHeight: StageLayout.ReviewPanel.safetyRow, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: Size.glyph))
                .foregroundStyle(AgentTheme.graphite)
                .accessibilityHidden(true)
            Text(
                "\(Text(LaunchpadCopy.Review.beforeYouApprove).font(AgentFont.captionSemibold).foregroundStyle(.primary)) \(Text(text).font(AgentFont.caption).foregroundStyle(.secondary))"
            )
            .wrapsLines()
        }
        .padding(.horizontal, Space.xs)
    }
}

/// An app's header over its steps: its mark, its name, and what it gets.
struct ReviewAppHeader: View {
    let client: ClientKind
    let summary: String

    var body: some View {
        HStack(spacing: Space.sm) {
            ClientBrandIcon(client: client, size: Size.brandMark)
                .accessibilityHidden(true)
            Text(client.rawValue)
                .font(AgentFont.bodySemibold)
            Text(summary)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: StageLayout.ReviewPanel.appHeader)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One step: its number (a spinner while it runs, a check once done), what it
/// does, and the well with what it runs or where it copies to. A step left
/// alone keeps its place with a dashed edge, the "–" index and its reason.
struct ReviewStepRow: View {
    let step: ScopedPlanReview.Step
    let accessibilityText: String

    var body: some View {
        if step.state == .leftAlone {
            leftAlone
        } else {
            HStack(alignment: .top, spacing: Space.lg) {
                ReviewIndexBadge(number: step.number, state: step.state)
                VStack(alignment: .leading, spacing: Space.xs) {
                    title
                    if let well = step.well { ReviewWell(well: well) }
                    if let note = step.note {
                        Text(note)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                    }
                    if case .failed(let reason) = step.state {
                        Text(reason)
                            .font(AgentFont.caption)
                            .foregroundStyle(AgentTheme.failure)
                            .lineLimit(2)
                            .wrapsLines()
                    }
                    if let risk = step.risk { PlanContentRiskPanel(report: risk) }
                }
                .padding(.top, Space.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var title: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: Self.symbol(for: step))
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(AgentFont.bodyMedium)
                .foregroundStyle(step.isChange ? .primary : .secondary)
                .lineLimit(1)
        }
    }

    private var leftAlone: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            ReviewIndexBadge(number: nil, state: .leftAlone)
            VStack(alignment: .leading, spacing: Space.xxs) {
                title
                if let note = step.note {
                    Text(note)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
            .padding(.top, Space.xxs)
            Spacer(minLength: Space.md)
            Text(LaunchpadCopy.Review.leftAloneState)
                .font(AgentFont.captionMedium)
                .foregroundStyle(.secondary)
                .padding(.top, Space.xs)
        }
        .padding(.vertical, Space.md)
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle.control
                .strokeBorder(
                    HairlineStyle(base: Color.primary.opacity(Opacity.dashedHairline)),
                    style: StrokeStyle(lineWidth: Hairline.width, dash: Hairline.dash))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// PlanStepRow's symbol for what a step does; a step left alone raises
    /// its hand.
    static func symbol(for step: ScopedPlanReview.Step) -> String {
        if step.state == .leftAlone { return "hand.raised" }
        switch step.action {
        case .copy: return "arrow.down.circle"
        case .update: return "arrow.triangle.2.circlepath"
        case .remove, .disconnect: return "trash"
        case .plugin: return "puzzlepiece.extension"
        case .connection: return "cable.connector"
        }
    }
}

/// A step's index: its number on a quiet disc, a spinner while it runs, a
/// check that draws on once it is done, a cross if it failed, and "–" for a
/// step that does not run.
struct ReviewIndexBadge: View {
    let number: Int?
    let state: ScopedPlanReview.StepState
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state {
            case .running:
                Circle().fill(AgentTheme.fillStrong)
                ProgressView()
                    .controlSize(.small)
            case .done:
                Circle().fill(AgentTheme.ok)
                Image(systemName: "checkmark")
                    .font(AgentFont.captionSemibold)
                    .foregroundStyle(.white)
                    .transition(drawsOn ? AnyTransition(.symbolEffect(.drawOn)) : .identity)
            case .failed:
                Circle().fill(AgentTheme.failure)
                Image(systemName: "xmark")
                    .font(AgentFont.captionSemibold)
                    .foregroundStyle(.white)
            case .waiting where number != nil:
                Circle().fill(AgentTheme.fillStrong)
                Text(number.map(String.init) ?? "")
                    .font(AgentFont.captionSemibold.monospacedDigit())
            case .waiting, .leftAlone, .willNotRun:
                Circle().strokeBorder(HairlineStyle(), lineWidth: Hairline.width)
                Text(LaunchpadCopy.Review.noNumber)
                    .font(AgentFont.captionSemibold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Size.indexBadge, height: Size.indexBadge)
        .animation(motion.resolved(reduceMotion: reduceMotion) == .full ? AgentMotion.quick : nil, value: state)
        .accessibilityHidden(true)
    }

    private var drawsOn: Bool { motion.resolved(reduceMotion: reduceMotion).animatesDetails }
}

/// A step's well: the commands it runs, each after a "$ ", or the folder a
/// copy lands in. Long lines wrap only at spaces and slashes, so a name or a
/// flag is never split.
///
/// What is drawn is set for reading, not for copying: its hyphens do not
/// break and its slashes may (`breakable`), so the text is not selectable,
/// and a command copied that way would fail in a shell. The copy button puts
/// the exact commands on the pasteboard (`plain`); it shows on hover and on
/// keyboard focus, and VoiceOver reaches it.
struct ReviewWell: View {
    let well: ScopedPlanReview.Well
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool
    @Environment(\.stageMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch well {
            case .path(let path):
                line(path, prompt: false)
            case .commands(let commands):
                ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                    line(command, prompt: true)
                }
            }
        }
        .textSelection(.disabled)
        .padding(.vertical, Space.sm)
        .padding(.leading, Space.lg)
        .padding(.trailing, StageLayout.ReviewPanel.wellTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.fillSubtle, in: RoundedRectangle.control)
        .overlay { RoundedRectangle.control.strokeBorder(HairlineStyle(base: AgentTheme.hairlineStroke), lineWidth: Hairline.width) }
        .overlay(alignment: .topTrailing) { copyButton }
        .onHover { inside in
            hovering = inside
            // "Copied" lasts while the pointer stays; the next visit offers
            // Copy again.
            if !inside { copied = false }
        }
    }

    private func line(_ text: String, prompt: Bool) -> some View {
        Group {
            if prompt {
                Text("\(Text(LaunchpadCopy.Review.prompt).foregroundStyle(.tertiary))\(Self.breakable(text))")
            } else {
                Text(Self.breakable(text))
            }
        }
        .font(AgentFont.mono)
        .lineHeight(.exact(points: StageLayout.ReviewPanel.wellLine))
        .wrapsLines()
        .accessibilityLabel(text)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.plain(well), forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: Size.glyphSmall))
                .foregroundStyle(copied ? AnyShapeStyle(AgentTheme.ok) : AnyShapeStyle(.secondary))
                .frame(width: StageLayout.ReviewPanel.copyButton, height: StageLayout.ReviewPanel.copyButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($copyFocused)
        .padding(Space.xs)
        // A still (a render) draws the resting well, wherever the pointer is.
        .opacity(Self.showsCopy(hovering: hovering, focused: copyFocused) && motion != .still ? 1 : 0)
        .onChange(of: copyFocused) { _, focused in
            if !focused { copied = false }
        }
        .accessibilityLabel(copied ? LaunchpadCopy.Review.copied : LaunchpadCopy.Review.copyWell)
        .help(LaunchpadCopy.Review.copyWell)
    }

    /// Whether the copy button shows: while the pointer is over the well, or
    /// while the keyboard is on the button.
    nonisolated static func showsCopy(hovering: Bool, focused: Bool) -> Bool {
        hovering || focused
    }

    /// What the copy button puts on the pasteboard: the exact lines, with
    /// none of the characters `breakable` draws them with.
    nonisolated static func plain(_ well: ScopedPlanReview.Well) -> String {
        switch well {
        case .path(let path): path
        case .commands(let commands): commands.joined(separator: "\n")
        }
    }

    /// `text` as a well sets it: a hyphen never breaks a line, and a slash
    /// may, so "agent-tooling" and "--scope" stay whole and a long path wraps
    /// at a folder.
    nonisolated static func breakable(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "\u{2011}").replacingOccurrences(of: "/", with: "/\u{200B}")
    }
}

/// A status beside its words, as the kit's `.st` draws it: a small glyph and
/// a medium caption.
struct ReviewStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            configuration.icon
                .font(.system(size: Size.glyphSmall))
            configuration.title
                .font(AgentFont.captionMedium)
                .foregroundStyle(.secondary)
        }
    }
}

extension LabelStyle where Self == ReviewStatusLabelStyle {
    static var reviewStatus: ReviewStatusLabelStyle { ReviewStatusLabelStyle() }
}

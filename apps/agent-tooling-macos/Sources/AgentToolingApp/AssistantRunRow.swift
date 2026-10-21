import AgentToolingCore
import SwiftUI

/// Shared assistant-consent row for setup and Settings. The data-sharing chip
/// stays visible even when disabled, and joins the switch's accessible label.
struct AssistantRunRow: View {
    let run: AssistantRunCopy.Run
    /// What the run reads and sends, with its paths; nothing when the line
    /// above the runs already says why it cannot run.
    let text: [AssistantRunCopy.Span]
    /// The weekly review's folders, under its words.
    var folderLine: AssistantRunCopy.Span?
    @Binding var isOn: Bool
    /// False when no app this Mac manages can run it.
    var isEnabled = true
    /// The sentence a save that failed left under the row.
    var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Text(AssistantRunCopy.title(run))
                    .font(AgentFont.bodySemibold)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Chip(text: AssistantRunCopy.chip(run))
                    .accessibilityHidden(true)
                Spacer(minLength: Space.md)
                Toggle(isOn: $isOn) {
                    Text(AssistantRunCopy.accessibilityLabel(run))
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isEnabled)
                .accessibilityHint(AssistantRunCopy.plain(text))
            }
            .frame(height: Size.chipHeight)
            if !text.isEmpty {
                Text(Self.attributed(text))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .frame(maxWidth: Size.proseMaxWidth, alignment: .leading)
                    .accessibilityHidden(true)
            }
            if let folderLine {
                Text(folderLine.text)
                    .font(folderLine.isPath ? AgentFont.mono : AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            if let failure { SaveFailureLine(text: failure) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1 : Opacity.unavailable)
        .accessibilityElement(children: .contain)
    }

    /// The spans as one text, each path in the mono face and kept whole: a
    /// line never breaks inside a path.
    static func attributed(_ spans: [AssistantRunCopy.Span]) -> AttributedString {
        var text = AttributedString()
        for span in spans {
            guard span.isPath else {
                text.append(AttributedString(span.text))
                continue
            }
            var part = AttributedString(span.text.replacingOccurrences(of: "/", with: "/\u{2060}"))
            part.font = AgentFont.mono
            text.append(part)
        }
        return text
    }
}

/// What a choice that did not save leaves under its row: the stage's one
/// sentence for it, in the failure colour, with its glyph.
struct SaveFailureLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: Size.glyphSmall))
                .accessibilityHidden(true)
            Text(text).wrapsLines()
        }
        .font(AgentFont.caption)
        .foregroundStyle(AgentTheme.failure)
        .accessibilityElement(children: .combine)
    }
}

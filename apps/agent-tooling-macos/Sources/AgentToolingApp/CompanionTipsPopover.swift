import AgentToolingCore
import SwiftUI

/// The tips behind the card's "Use it from Raycast or Terminal…": what the
/// Agent Tooling extension adds to Raycast, whether Raycast and the extension
/// are on this Mac, and the command-line tool to run in Terminal.
///
/// Raycast is looked for as the popover opens and not before (the card's
/// link looks, then opens it). A standalone view, so the gallery draws it as
/// Home shows it.
struct CompanionTipsPopover: View {
    /// Where Raycast stands, as looked for when the popover opened.
    let raycast: CompanionPresence.Raycast
    /// The command-line tool inside this copy, or nil for a copy without one.
    let helperPath: String?

    var body: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.raycast)
                .font(AgentFont.captionSemibold)
                .padding(.bottom, Space.xxs)
                .accessibilityAddTraits(.isHeader)
            Text(raycastSentence)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
                .padding(.top, Space.xs)
            Text(copy.terminal)
                .font(AgentFont.captionSemibold)
                .padding(.top, Space.md)
                .accessibilityAddTraits(.isHeader)
            if let helperPath {
                command(helperPath)
            } else {
                Text(copy.noCommandLineTool)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                    .padding(.top, Space.xs)
            }
            ForEach(copy.terminalCommands, id: \.self) { line in
                command(line)
            }
        }
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.lg)
        .frame(width: Size.fieldWide, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var raycastSentence: String {
        let copy = LaunchpadCopy.FinishSetup.self
        let commands = CompanionPresence.raycastCommands
        switch raycast {
        case .appOnly: return copy.raycastWithoutExtension(commands)
        case .extensionInstalled: return copy.raycastWithExtension(commands)
        case .absent: return copy.noRaycast(commands)
        }
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.mono)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .wrapsLines()
            .padding(.top, Space.xxs)
    }
}

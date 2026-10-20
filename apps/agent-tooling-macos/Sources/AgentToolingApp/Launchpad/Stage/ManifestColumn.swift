import SwiftUI

/// Consent and progress list for one client's paths and commands. Equal reserved
/// path rows align command sections across clients. Status distinguishes pending,
/// reading, completed, shared, and unexpected locations.
struct ManifestColumn: View {
    /// One line of the list.
    struct Line: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case idle
            case reading
            case read
            /// Read once, for an earlier app: drawn with the link glyph.
            case linked
            /// Read, but not on the list.
            case unlisted
        }

        let id: String
        let text: String
        var state: State
        /// The full words, when `text` is shortened to fit.
        var accessibilityText: String?
        /// Words after the path, set smaller and in the text face: a shared
        /// place's "with Codex".
        var suffix: String?

        init(id: String, text: String, state: State = .idle, accessibilityText: String? = nil, suffix: String? = nil) {
            self.id = id
            self.text = text
            self.state = state
            self.accessibilityText = accessibilityText
            self.suffix = suffix
        }
    }

    let reads: [Line]
    let runs: [Line]
    var reservedReadLines = StageLayout.Reads.readLinesReserved
    /// What VoiceOver says before the lines: "Codex reads 4 places and runs
    /// 3 commands".
    var accessibilitySummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StageListLabel(LaunchpadCopy.Kit.readsLabel)
                .frame(height: StageLayout.Reads.manifestLine, alignment: .leading)
                .padding(.bottom, Space.xxs)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(reads) { ManifestLine(line: $0) }
            }
            .frame(height: StageLayout.Reads.manifestLine * CGFloat(reservedReadLines), alignment: .top)
            .padding(.bottom, Space.xs)
            StageListLabel(LaunchpadCopy.Kit.runsLabel)
                .frame(height: StageLayout.Reads.manifestLine, alignment: .leading)
                .padding(.bottom, Space.xxs)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(runs) { ManifestLine(line: $0) }
            }
        }
        .frame(width: StageLayout.Well.column, alignment: .topLeading)
        .padding(.top, StageLayout.Reads.manifestTop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary ?? "")
    }
}

/// One line of a manifest: its state slot, then its words.
struct ManifestLine: View {
    let line: ManifestColumn.Line
    @Environment(\.stageMotion) private var motion

    var body: some View {
        HStack(spacing: Space.sm) {
            slot
                .frame(width: StageLayout.Reads.slot, height: StageLayout.Reads.slot)
            HStack(spacing: Space.xxs) {
                Text(line.text)
                    .font(AgentFont.monoMicro)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let suffix = line.suffix {
                    Text(suffix)
                        .font(AgentFont.micro)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: StageLayout.Well.column, alignment: .leading)
        .frame(height: StageLayout.Reads.manifestLine)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText ?? line.text)
    }

    @ViewBuilder private var slot: some View {
        switch line.state {
        case .idle:
            Circle()
                .fill(.tertiary)
                .frame(width: StageLayout.Reads.idleDot, height: StageLayout.Reads.idleDot)
        case .reading:
            ProgressView().controlSize(.mini)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: StageLayout.Reads.slot))
                .foregroundStyle(AgentTheme.ok)
        case .linked:
            Image(systemName: "link")
                .font(.system(size: StageLayout.Reads.linkGlyph))
                .foregroundStyle(.secondary)
        case .unlisted:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: StageLayout.Reads.slot))
                .foregroundStyle(AgentTheme.warning)
        }
    }
}

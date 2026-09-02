import AgentToolingCore
import SwiftUI

struct ConduitTerminal: Identifiable {
    let client: ClientKind
    let state: HealthState
    let text: String
    var id: ClientKind { client }
}

/// The product's signature: library → configuration → clients drawn as one
/// path. The path draws itself in when the screen appears, the trunk flows
/// while something needs attention, and every terminal carries that client's
/// own verdict. All motion stops under Reduce Motion.
struct SyncConduitView: View {
    let managedCount: Int
    let discoveredCount: Int
    let profileName: String
    let desiredCount: Int
    let pendingCount: Int
    let terminals: [ConduitTerminal]
    let onLibrary: () -> Void
    let onProfile: () -> Void
    let onClient: (ClientKind) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private let terminalHeight: CGFloat = 34
    private let terminalSpacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            node(kind: .library, title: "Library", detail: libraryDetail, action: onLibrary)
                .revealed(revealed, delay: 0, reduceMotion: reduceMotion)
            straightConnector
                .frame(width: 72, height: connectorHeight)
            node(kind: .profile, title: profileName, detail: profileDetail, action: onProfile)
                .revealed(revealed, delay: 0.18, reduceMotion: reduceMotion)
            branchConnector
                .frame(width: 112, height: connectorHeight)
            VStack(spacing: terminalSpacing) {
                ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                    TerminalCapsule(terminal: terminal, height: terminalHeight) {
                        onClient(terminal.client)
                    }
                    .revealed(revealed, delay: 0.42 + Double(index) * 0.08, reduceMotion: reduceMotion)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
        .onAppear {
            DispatchQueue.main.async { revealed = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sync path from the library through \(profileName) to \(terminals.count) clients")
    }

    private var connectorHeight: CGFloat {
        CGFloat(terminals.count) * terminalHeight + CGFloat(max(0, terminals.count - 1)) * terminalSpacing
    }

    private var libraryDetail: String {
        discoveredCount > 0 ? "\(managedCount) managed · \(discoveredCount) discovered" : "\(managedCount) managed"
    }

    private var profileDetail: String {
        "Configuration · \(desiredCount) \(desiredCount == 1 ? "item" : "items") desired"
    }

    private var lineAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.65).delay(0.12)
    }

    private func node(kind: ToolingKind, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                KindTile(kind: kind, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var straightConnector: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .trim(from: 0, to: revealed ? 1 : 0)
            .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .animation(lineAnimation, value: revealed)
        }
    }

    private var branchConnector: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let mid = height / 2
            let split = width * 0.34
            let pending = pendingCount > 0
            let animate = pending && !reduceMotion

            ZStack(alignment: .bottom) {
                TimelineView(.animation(paused: !animate)) { context in
                    let phase =
                        animate
                        ? -CGFloat(context.date.timeIntervalSinceReferenceDate * 16).truncatingRemainder(dividingBy: 18)
                        : 0
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: mid))
                        path.addLine(to: CGPoint(x: split, y: mid))
                    }
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(
                        pending ? AgentTheme.blue : Color.secondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.75, lineCap: .round, dash: pending ? [4, 5] : [], dashPhase: phase)
                    )
                    .animation(lineAnimation, value: revealed)
                }

                ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                    let y = terminalHeight / 2 + CGFloat(index) * (terminalHeight + terminalSpacing)
                    let control = split + (width - split) * 0.55
                    let attention = terminal.state == .attention || terminal.state == .unavailable
                    TimelineView(.animation(paused: !(attention && animate))) { context in
                        let phase =
                            attention && animate
                            ? -CGFloat(context.date.timeIntervalSinceReferenceDate * 16).truncatingRemainder(dividingBy: 18)
                            : 0
                        Path { path in
                            path.move(to: CGPoint(x: split, y: mid))
                            path.addCurve(
                                to: CGPoint(x: width, y: y),
                                control1: CGPoint(x: control, y: mid),
                                control2: CGPoint(x: control, y: y)
                            )
                        }
                        .trim(from: 0, to: revealed ? 1 : 0)
                        .stroke(
                            attention ? AgentTheme.warning : Color.secondary.opacity(0.45),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: attention ? [4, 5] : [], dashPhase: phase)
                        )
                        .animation(lineAnimation.map { $0.delay(0.1) }, value: revealed)
                    }
                }

                if pending {
                    Text("\(pendingCount) \(pendingCount == 1 ? "item needs" : "items need") attention")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentTheme.blue)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .offset(y: 3)
                        .revealed(revealed, delay: 0.5, reduceMotion: reduceMotion)
                }
            }
        }
    }
}

/// One client at the end of the path: brand mark, name, verdict. Lifts a
/// little on hover so it reads as the button it is.
private struct TerminalCapsule: View {
    let terminal: ConduitTerminal
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ClientDisc(client: terminal.client, size: 28, bordered: false)
                Text(terminal.client.rawValue)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(minWidth: 76, alignment: .leading)
                StatusBadge(state: terminal.state, text: terminal.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 3)
            .padding(.trailing, 12)
            .frame(height: height)
            .background {
                Capsule()
                    .fill(AgentTheme.controlBackground)
                    .shadow(color: .black.opacity(hovering ? 0.14 : 0.05), radius: hovering ? 6 : 1, y: hovering ? 3 : 1)
            }
            .overlay {
                Capsule().strokeBorder(AgentTheme.separator.opacity(hovering ? 0.8 : 0.5), lineWidth: 0.5)
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .accessibilityLabel("\(terminal.client.rawValue), \(terminal.text)")
    }
}

private extension View {
    /// Fade and slide in once, staggered by `delay`; instant under Reduce Motion.
    func revealed(_ revealed: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(revealed ? 1 : 0)
            .offset(x: revealed ? 0 : -8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(delay), value: revealed)
    }
}

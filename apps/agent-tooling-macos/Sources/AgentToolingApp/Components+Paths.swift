import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Installation map

/// Paths never sit in a row. A short name identifies the place; the ⓘ opens a
/// popover with the full location and a Reveal in Finder link.
struct LocationText: View {
    let path: String
    var label: String?

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(label ?? LocationText.shortName(for: path))
                .font(AgentFont.body)
                .lineLimit(1)
                .truncationMode(.middle)
            PathInfoButton(path: path)
        }
    }

    static func shortName(for path: String) -> String {
        if let components = URLComponents(string: path),
            let scheme = components.scheme,
            let host = components.host,
            !scheme.isEmpty,
            !host.isEmpty
        {
            let suffix = components.path.split(separator: "/").suffix(1).first.map(String.init)
            return suffix.map { "\(host) / \($0)" } ?? host
        }
        let components = URL(fileURLWithPath: path).standardized.pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return components.joined(separator: " / ") }
        return components.suffix(2).joined(separator: " / ")
    }
}

struct PathInfoButton: View {
    let path: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: Size.glyphSmall, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: Size.chipHeight, height: Size.chipHeight)
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("Show location")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(isWebURL ? "Address" : "Location")
                    .font(AgentFont.captionSemibold)
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(AgentFont.mono)
                    .textSelection(.enabled)
                    .wrapsLines()
                if canReveal {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .inlineActionStyle()
                    .font(AgentFont.caption)
                }
            }
            .padding(Space.lg)
            .frame(minWidth: 220, maxWidth: 440, alignment: .leading)
        }
    }

    private var isWebURL: Bool {
        guard let components = URLComponents(string: path), let scheme = components.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && components.host?.isEmpty == false
    }

    private var canReveal: Bool {
        !isWebURL && FileManager.default.fileExists(atPath: path)
    }
}

/// Kept for the plan review and settings, where the exact path is the point.
struct CompactPathText: View {
    let path: String
    var lineLimit = 1

    var body: some View {
        Text(displayPath)
            .font(AgentFont.mono)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .help(path)
            .accessibilityLabel(path)
    }

    private var displayPath: String {
        if let components = URLComponents(string: path),
            let scheme = components.scheme,
            let host = components.host,
            !scheme.isEmpty,
            !host.isEmpty
        {
            let suffix = components.path.split(separator: "/").suffix(1).first.map(String.init)
            return suffix.map { "\(host)/…/\($0)" } ?? host
        }

        let components = URL(fileURLWithPath: path).standardized.pathComponents
        guard components.count > 3 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
/// Native table cells can be recycled while their enclosing view is changing.
/// Keep their content independent of required observable environment objects.
///
/// An app without the item leaves an empty ring in its slot (`AbsentMark`), so
/// a column of marks says who has it by shape, not by how faded a mark is.
struct TableClientMarks: View {
    let clients: [ClientKind]
    let present: Set<ClientKind>

    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(clients) { client in
                if present.contains(client) {
                    ClientBrandIcon(client: client, size: Size.brandMark).help(client.rawValue)
                } else {
                    AbsentMark(size: Size.brandMark).help("Not in \(client.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clients.filter(present.contains).map(\.rawValue).joined(separator: ", "))
    }
}

// MARK: - Layout

/// Wraps pills onto as many rows as they need. Tag and filter rows are the
/// only things that use it, and both must reflow rather than truncate.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = cursorX == 0 ? size.width : cursorX + spacing + size.width
            if cursorX > 0, nextWidth > maximumWidth {
                cursorY += rowHeight + spacing
                cursorX = size.width
                rowHeight = size.height
            } else {
                cursorX = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
            measuredWidth = max(measuredWidth, cursorX)
        }
        return CGSize(width: proposal.width.map { min($0, measuredWidth) } ?? measuredWidth, height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: cursorX, y: cursorY), anchor: .topLeading, proposal: .unspecified)
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

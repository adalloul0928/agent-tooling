import AgentToolingCore
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The row grammar every screen is built from.
///
/// These primitives have no session behind them and no test of their own
/// elsewhere, so a component that compiles but lays out to nothing is invisible
/// until eight ported screens are all drawing blanks with it. That is the one
/// failure worth catching here; exact pixels are not.
@Suite("Chrome primitives render")
@MainActor
struct ComponentsRenderTests {
    private static let clients: [ClientState] = [
        ClientState(client: .codex, state: .healthy, detail: "Installed", revision: "1.4.0"),
        ClientState(client: .claude, state: .attention, detail: "Needs a repair"),
        ClientState(client: .gemini, state: .pending, detail: "Not checked"),
    ]

    @Test("Every restored primitive draws something")
    func primitivesDraw() throws {
        let cases: [(String, AnyView)] = [
            ("SymbolTile", AnyView(SymbolTile(symbol: "shippingbox"))),
            ("KindTile", AnyView(KindTile(kind: .skill))),
            ("ClientDisc", AnyView(ClientDisc(client: .codex))),
            ("ClientMarks", AnyView(ClientMarks(present: [.codex]))),
            ("TableClientMarks", AnyView(TableClientMarks(clients: ClientKind.allCases, present: [.claude]))),
            ("SelectionRowBackground", AnyView(SelectionRowBackground(selected: true).frame(width: 200, height: 32))),
            ("StatusGlyph", AnyView(StatusGlyph(state: .attention))),
            ("StatusBadge", AnyView(StatusBadge(state: .healthy, text: "Up to date"))),
            ("SectionCaption", AnyView(SectionCaption(text: "Managed by this Mac"))),
            ("SelectionCheckbox", AnyView(SelectionCheckbox(selected: true))),
            ("UpdateStateBadge", AnyView(UpdateStateBadge(availability: .updateAvailable(installed: "1.0", available: "1.1")))),
            ("ToolIdentityIcon", AnyView(ToolIdentityIcon(packageID: "github@openai-curated-remote"))),
            (
                "AttentionBanner",
                AnyView(AttentionBanner(title: "Two apps need a check", message: "Nothing was changed.").frame(width: 460))
            ),
            ("InspectorHeader", AnyView(InspectorHeader(title: "Details") {}.frame(width: 320))),
            ("PanelHeader", AnyView(PanelHeader("Installation map").frame(width: 320))),
            (
                "SelectionActionBar",
                AnyView(SelectionActionBar(count: 3, actionTitle: "Add to preset", action: {}, clear: {}).frame(width: 420))
            ),
            ("CommandDisclosure", AnyView(CommandDisclosure(title: "Repair command", command: "codex mcp repair").frame(width: 420))),
            ("ClientStatusRows", AnyView(ClientStatusRows(clients: Self.clients).frame(width: 420))),
            ("TagCloud", AnyView(TagCloud(tags: ["review", "writing", "shell"]).frame(width: 320))),
            ("CollectionPills", AnyView(CollectionPills(names: ["Writing", "Review", "Shell"]))),
            ("TagPills", AnyView(TagPills(tags: ["review", "writing", "shell", "swift"]))),
            ("FilterPill", AnyView(FilterPill(title: "Untagged", count: 4, isOn: true, action: {}))),
            ("LocationText", AnyView(LocationText(path: "/Users/example/Library/Application Support/agent-tooling"))),
            ("CompactPathText", AnyView(CompactPathText(path: "/Users/example/Library/Application Support/agent-tooling"))),
            ("PathInfoButton", AnyView(PathInfoButton(path: "https://example.invalid/catalog"))),
            (
                "LabeledValueRow",
                AnyView(LabeledValueRow("Installed revision") { Text("1.4.0") }.frame(width: 420))
            ),
            (
                "InfoRow",
                AnyView(
                    InfoRow("Deep research", detail: "Runs in Codex") {
                        KindTile(kind: .skill)
                    } trailing: {
                        StatusBadge(state: .healthy, text: "Assigned")
                    }
                    .frame(width: 460))
            ),
            (
                "TitledCard",
                AnyView(
                    TitledCard("Library", count: "12 items") {
                        InfoRow("Deep research", detail: "Runs in Codex") { KindTile(kind: .skill) }
                    }
                    .frame(width: 460))
            ),
            (
                "EmptyStateView",
                AnyView(
                    EmptyStateView(
                        symbol: "square.stack", title: "No presets yet",
                        message: "A preset is a shelf you can hand to a project.",
                        actionTitle: "New preset", action: {}
                    )
                    .frame(width: 460, height: 320))
            ),
            (
                "TagFilterBar",
                AnyView(
                    TagFilterBar(
                        tags: ["review", "writing"], untaggedCount: 4,
                        selection: .constant(["review"]), untaggedOnly: .constant(false)
                    )
                    .frame(width: 360))
            ),
        ]

        for (name, view) in cases {
            try expectDrawn(view, name)
        }
    }

    /// The toolbar reads its tab row out of the environment, so it has to be
    /// correct twice: standing alone in a preview or a ported screen that no
    /// shell has wrapped yet, and inside the shell once one does.
    @Test("The page toolbar degrades to a plain heading with no shell around it")
    func toolbarWithoutEnvironmentShowsNoTabs() throws {
        let bare = try measure(toolbar(title: "Library"))
        let inShell = try measure(toolbar(title: "Library").environment(\.workspaceSelection, .skills))
        let noTabs = try measure(toolbar(title: "Home").environment(\.workspaceSelection, .overview))

        #expect(bare.height > 0)
        #expect(inShell.height > bare.height, "the Library tab row did not appear")
        #expect(noTabs.height == bare.height, "a section with no tabs grew a tab row")
    }

    @Test("Choosing a tab asks the shell to navigate rather than navigating itself")
    func toolbarTabsReportThroughTheEnvironment() throws {
        let requested = Requests()
        let view = toolbar(title: "Library")
            .environment(\.workspaceSelection, .skills)
            .environment(\.workspaceNavigate, { requested.sections.append($0) })

        try expectDrawn(view, "PageToolbar in the Library family")
        #expect(requested.sections.isEmpty, "drawing the toolbar navigated on its own")
    }

    /// With no shell publishing a client list, one row on its own still has to
    /// show all three marks; the alternative is a row that silently claims a
    /// tool is unavailable everywhere.
    @Test("Client marks fall back to every known client")
    func clientMarksFallBackToAllClients() throws {
        let all = try measure(ClientMarks(present: [.codex]))
        let one = try measure(ClientMarks(present: [.codex]).environment(\.availableClients, [.codex]))

        #expect(all.width > one.width)
    }

    @Test("A location names a place; the path itself stays behind the popover")
    func locationsAreNamedNotSpelledOut() {
        #expect(
            LocationText.shortName(for: "/Users/example/Library/Application Support/agent-tooling")
                == "Application Support / agent-tooling")
        #expect(LocationText.shortName(for: "/etc/hosts") == "etc / hosts")
        #expect(
            LocationText.shortName(for: "https://example.invalid/catalog/index.json")
                == "example.invalid / index.json")
        #expect(LocationText.shortName(for: "https://example.invalid") == "example.invalid")
    }

    /// Proves the blank-frame check above can fail.
    @Test("The blank-frame check would catch a primitive that drew nothing")
    func blankFrameCheckCanFail() throws {
        let bitmap = try rasterize(Color(nsColor: .windowBackgroundColor).frame(width: 120, height: 40), "blank")
        #expect(distinctColours(in: bitmap) < 2)
    }

    private final class Requests {
        var sections: [AppSection] = []
    }

    private func toolbar(title: String) -> some View {
        PageToolbar(title: title, context: "12 items") {
            Button("Add") {}
        }
        .frame(width: 900)
    }

    private func expectDrawn(_ view: some View, _ name: String, _ location: SourceLocation = #_sourceLocation) throws {
        let bitmap = try rasterize(view, name, location)
        #expect(distinctColours(in: bitmap) >= 2, "\(name) drew a blank frame", sourceLocation: location)
    }

    /// Lays a primitive out at its own intrinsic size rather than in a window,
    /// so a badge is measured against its own few hundred pixels instead of
    /// being lost in a wash of page background.
    private func measure(_ view: some View, _ location: SourceLocation = #_sourceLocation) throws -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.fixedSize()))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width > 0 && size.height > 0, "laid out to nothing", sourceLocation: location)
        return size
    }

    private func rasterize(
        _ view: some View, _ name: String, _ location: SourceLocation = #_sourceLocation
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.fixedSize()))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width > 0, "\(name) laid out to no width", sourceLocation: location)
        #expect(size.height > 0, "\(name) laid out to no height", sourceLocation: location)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "\(name) produced no drawable area", sourceLocation: location)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Counts colours over the whole primitive. A drawn one puts at least a
    /// glyph or a word over its ground; a blank one is a single flat wash.
    private func distinctColours(in bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let packed =
                    UInt32(colour.redComponent * 255) << 16
                    | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255)
                seen.insert(packed)
                if seen.count >= 2 { return seen.count }
            }
        }
        return seen.count
    }
}

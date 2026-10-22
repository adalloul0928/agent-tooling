import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Late content on the stage scrolls inside its region and never pushes past
/// the slot or grows the window (brief §7). Each screen with a list that
/// grows with the library draws it in a region that scrolls: S06's list,
/// S08's skills, S10's grid, the review panel's steps and Done's columns
/// scroll in their own scroll views, and You joined's arrivals in
/// `scrollsWhenFull()`, which keeps a short list at its own height.
@Suite("Launchpad · stage regions scroll", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct StageRegionsScrollTests {
    private static let region = CGSize(width: 320, height: 300)

    /// A short list keeps its own height; a long one stays in the room it is
    /// given and scrolls there, and what follows it stays in view.
    @Test func aRegionKeepsItsHeightUntilItIsFullThenScrolls() {
        let marker = Hairline.width
        #expect(Self.bottomOfList(rows: 2) == Size.rowHeight * 2 + marker, "a short list does not keep its own height")
        #expect(Self.bottomOfList(rows: 40) == Self.region.height, "a long list pushes past its region")
    }

    /// You joined with twelve arrivals, more than its card has room for,
    /// landing after the stage has laid out: the stage keeps its window, the
    /// arrivals scroll inside the card, the last of them is still there to
    /// reach, and Agent Tooling's own row stays in view above the footer.
    /// With the walk's own three, nothing scrolls.
    @Test func youJoinedsArrivalsScrollWhenThereAreMoreThanFit() async throws {
        let scene = try await MacsScene.j02(.checking, sharing: 9)
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: scene.flow))
        let layout = try await LateContentHarness.heightAfterChange(
            scene.view, windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            await arrivals.load()
        }
        #expect(arrivals.rows.count == 12, "\(arrivals.rows.count) arrived, not 12")
        #expect(layout.hostHeight == layout.windowHeight)

        let window = Self.stageWindow(scene.view)
        let probe = AccessibilityProbe(reading: window)
        let footer = try #require(probe.elements.first { $0.role == .group && $0.label == LaunchpadCopy.Footer.groupLabel })
        let own = try #require(probe.elements.first { $0.value == LaunchpadCopy.Join.ownConnection })
        // Screen coordinates: up is a larger y.
        #expect(own.frame.minY >= footer.frame.maxY, "Agent Tooling's own row is under the footer: \(own.frame), \(footer.frame)")
        let last = try #require(arrivals.rows.last)
        #expect(probe.elements.contains { $0.label.hasPrefix(last.name) }, "\(last.name) cannot be reached")
        #expect(!Self.scrollingViews(in: window).isEmpty, "the arrivals do not scroll")
        window.orderOut(nil)
        await scene.close()

        let few = try await MacsScene.j02(.ready)
        let fewWindow = Self.stageWindow(few.view)
        #expect(Self.scrollingViews(in: fewWindow).isEmpty, "the walk's three arrivals scroll")
        fewWindow.orderOut(nil)
        await few.close()
    }

    /// Done with a rerun's eight findings on Checkup: the Left for later card
    /// shows the whole list, Done's columns scroll inside the stage and show
    /// the system's scroller, Runs on its own is there to scroll to, and the
    /// key strip stays at the stage's foot under the columns.
    @Test func donesColumnsScrollWhenCheckupsListIsLong() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await LaunchpadDoneRenderTests.juniperAtDone(fixture)
        var inputs = FinishSetupFixture.juniperInputs()
        inputs.facts.openFindings = Self.eightFindings
        let summary = LaunchpadDoneSummary(inputs)
        let detail = try #require(summary.leftForLater.first { $0.item == .lookAtCheckup }?.detail)
        let view = SetupStage(managedClients: [.codex, .claude, .gemini]) {
            LaunchpadDoneContent(summary: summary)
        } footer: {
            StageFooterBar(info: flow.info, spec: LaunchpadStageView.footer(for: flow))
        } overlay: {
            EmptyView()
        }
        .environment(\.stageMotion, .still)
        .environment(\.snapshotNow, ClientHomeFixture.now)

        let window = Self.stageWindow(view)
        defer { window.orderOut(nil) }
        let probe = AccessibilityProbe(reading: window)
        #expect(probe.elements.contains { $0.label.contains(detail) || $0.value?.contains(detail) == true }, "the list is cut short")
        // Its column label, read with its qualifier.
        #expect(
            probe.elements.contains { $0.label.localizedCaseInsensitiveContains(LaunchpadCopy.Done.runsOnItsOwn) },
            "Runs on its own cannot be reached")
        let columns = try #require(Self.scrollingViews(in: window).first, "Done's columns do not scroll")
        #expect(columns.hasVerticalScroller, "Done's columns hide that they scroll")
        let search = LaunchpadCopy.Done.key(
            LaunchpadCopy.Done.keySearch, spoken: KeyCombo.spoken(KeyboardShortcut("k", modifiers: .command)))
        let strip = try #require(probe.elements.first { $0.label == search })
        let visible = window.convertToScreen(columns.convert(columns.bounds, to: nil))
        #expect(strip.frame.maxY <= visible.minY + Hairline.width, "the key strip is under the columns: \(strip.frame), \(visible)")
    }

    // MARK: - Helpers

    /// Juniper's four findings and four more: Frontend Design unmanaged in
    /// each app, and Release Notes in Claude Code.
    private static let eightFindings: [FinishSetupFacts.Finding] =
        FinishSetupFixture.juniperFindings + [
            .init(
                id: "frontend-codex", kind: .unmanagedSkill, name: "Frontend Design", apps: [.codex],
                title: "frontend-design is not managed by this app"),
            .init(
                id: "frontend-claude", kind: .unmanagedSkill, name: "Frontend Design", apps: [.claude],
                title: "frontend-design is not managed by this app"),
            .init(
                id: "frontend-gemini", kind: .unmanagedSkill, name: "Frontend Design", apps: [.gemini],
                title: "frontend-design is not managed by this app"),
            .init(
                id: "release-claude", kind: .unmanagedSkill, name: "Release Notes", apps: [.claude],
                title: "release-notes is not managed by this app"),
        ]

    /// `view` in a window of the stage's size and shape, on screen and
    /// settled.
    private static func stageWindow(_ view: some View) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.frame(width: WindowSize.stage.width, height: WindowSize.stage.height)))
        host.frame = CGRect(origin: .zero, size: WindowSize.stage)
        let window = NSWindow(
            contentRect: host.frame, styleMask: LateContentHarness.stageWindowStyle, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        settle()
        return window
    }

    /// The scroll views in `window` that hold more than they show.
    private static func scrollingViews(in window: NSWindow) -> [NSScrollView] {
        func found(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(found)
        }
        return (window.contentView.map(found) ?? []).filter { scroll in
            (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + Hairline.width
        }
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    /// Where a one-point marker under `rows` rows ends, in a region that has
    /// a spacer under the marker, as the stage's screens do.
    private static func bottomOfList(rows: Int) -> CGFloat {
        let bottom = Measured()
        let view = VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    Text(verbatim: "Row \(row)").frame(height: Size.rowHeight)
                }
            }
            .scrollsWhenFull()
            .layoutPriority(1)
            Color.clear
                .frame(height: Hairline.width)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .global).maxY
                } action: {
                    bottom.value = $0
                }
            Spacer(minLength: 0)
        }
        .frame(width: region.width, height: region.height)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: region)
        host.layoutSubtreeIfNeeded()
        return bottom.value
    }
}

/// A value a view reports as it lays out.
@MainActor
private final class Measured {
    var value: CGFloat = 0
}

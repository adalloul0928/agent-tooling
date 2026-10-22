import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The fixes the side-by-side pass against the mockups made, each pinned
/// where it was seen: Done's Left for later card when Checkup's list is long
/// (Done's columns scrolling is `StageRegionsScrollTests`'), Home's Finish
/// setting up card under Home's own type, and Join's read count.
@Suite("Launchpad · the mockup pass", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadPolishRenderTests {
    /// Done's right-hand column: what is left of the 796 pt slot beside What
    /// happened.
    private static let laterWidth = StageLayout.Grid.contentWidth - StageLayout.Done.leftColumn - StageLayout.Done.columnGap

    /// The rerun's eight findings: five lines, which push Runs on its own
    /// below the columns' fold, so they scroll.
    private static let eightFindings =
        "Frontend Design unmanaged in Codex, in Claude Code and in Gemini CLI; Release Notes unmanaged in Claude Code; "
        + "Webapp Testing unmanaged in Codex and in Claude Code; Context7 and Playwright each configured in two apps"
    /// Juniper's four, as the fragment draws them: three lines.
    private static let fourFindings =
        "Webapp Testing unmanaged in Codex and in Claude Code; Context7 and Playwright each configured in two apps"

    /// S22: a Left for later card's detail wraps in full, however long
    /// Checkup's list is (brief §7: long content wraps, and Done's columns
    /// scroll); VoiceOver reads the whole list.
    @Test func aLongCheckupListWrapsInFull() throws {
        let long = Self.card(detail: Self.eightFindings)
        let drawn = Self.card(detail: Self.fourFindings)
        let short = Self.card(detail: "Webapp Testing unmanaged in Codex")
        #expect(Self.height(of: long) > Self.height(of: drawn), "the long list was cut short at the drawn card's height")
        #expect(Self.height(of: short) < Self.height(of: drawn), "the three-line card is no taller than one line")

        let probe = AccessibilityProbe(long.frame(width: Self.laterWidth), size: CGSize(width: Self.laterWidth, height: 160))
        defer { probe.close() }
        #expect(
            probe.elements.contains { $0.label.contains(Self.eightFindings) || $0.value?.contains(Self.eightFindings) == true },
            "VoiceOver no longer hears the whole list: \(probe.elements.map { "\($0.role?.rawValue ?? "-") [\($0.label)] [\($0.value ?? "")]" })"
        )
    }

    /// P01: Hide keeps the card's own size on Home, whose page sets a larger
    /// type on everything under it.
    @Test(arguments: [RenderAppearance.light, .dark])
    func hideKeepsItsSizeOnHome(appearance: RenderAppearance) throws {
        let facts = FinishSetupFixture.juniperFacts(record: FinishSetupFixture.record(.juniper))
        let list = try #require(FinishSetupChecklist.make(facts, now: FinishSetupFixture.doneAt))
        let size = CGSize(width: 1_120, height: 440)
        let alone = AccessibilityProbe(FinishSetupCardBody(list: list).environment(\.snapshotNow, FinishSetupFixture.doneAt), size: size)
        defer { alone.close() }
        // Home's ScrollView sets AgentFont.titleRegular on all its content.
        let onHome = AccessibilityProbe(
            FinishSetupCardBody(list: list).font(AgentFont.titleRegular).environment(\.snapshotNow, FinishSetupFixture.doneAt),
            size: size)
        defer { onHome.close() }
        let hide = LaunchpadCopy.FinishSetup.hide
        let aloneWidth = try #require(alone.button(hide)?.frame.width)
        let homeWidth = try #require(onHome.button(hide)?.frame.width)
        #expect(aloneWidth > 0)
        #expect(homeWidth == aloneWidth, "Hide takes Home's type: \(homeWidth) wide on Home, \(aloneWidth) alone")
    }

    /// J01 and V08: the apps strip's read count is one line, as the fragment
    /// sets it, running into the gap before the tiles; a count too long for
    /// that wraps rather than reaching the tiles.
    @Test func joinsReadCountIsOneLine() throws {
        let copy = LaunchpadCopy.Join.self
        let line = NSHostingView(rootView: Text(verbatim: "Reads").font(AgentFont.caption)).fittingSize.height
        func height(_ text: String) -> CGFloat {
            let count = Text(text).font(AgentFont.caption).wrapsLines()
                .frame(width: StageLayout.Join.readCountWidth, alignment: .leading)
            return NSHostingView(rootView: count).fittingSize.height
        }
        #expect(height(copy.reads(places: 9, commands: 8)) == line, "Cedar's public count takes more than one line")
        #expect(height(copy.reads(places: 10, commands: 8)) == line, "Cedar's private count takes more than one line")
        #expect(height(copy.reads(places: 1_017, commands: 1_010)) > line, "a long count no longer wraps")
    }

    // MARK: - Helpers

    private static func card(detail: String) -> DoneLaterCard {
        DoneLaterCard(
            later: .init(
                item: .lookAtCheckup, state: .attention, title: LaunchpadCopy.Done.leftOnCheckup(8), detail: detail))
    }

    /// The card's height at Done's right-hand column width.
    private static func height(of card: DoneLaterCard) -> CGFloat {
        let host = NSHostingView(rootView: card.frame(width: laterWidth))
        return host.fittingSize.height
    }
}

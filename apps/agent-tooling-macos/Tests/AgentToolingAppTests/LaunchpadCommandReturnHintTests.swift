import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// A plain ↩ on a screen where only ⌘↩ acts says what ⌘↩ does there: the
/// review installs, Your other Macs connects, Join joins. Each primary
/// carries its own hint through `StageFooterSpec`, shown beside it, spoken,
/// and on the button for VoiceOver. The connect and join words are NEW copy
/// (owner flag O6).
@Suite("Launchpad · the ⌘↩ hint", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadCommandReturnHintTests {
    @Test func eachHintSaysWhatItsPrimaryDoes() {
        let copy = LaunchpadCopy.Footer.self
        #expect(copy.commandReturnHint == "Press ⌘↩ to install")
        #expect(copy.commandReturnSpoken == "Press Command-Return to install.")
        #expect(copy.commandReturnAccessibilityHint == "Command-Return installs.")
        #expect(copy.commandReturnConnectHint == "Press ⌘↩ to connect")
        #expect(copy.commandReturnConnectSpoken == "Press Command-Return to connect.")
        #expect(copy.commandReturnConnectAccessibilityHint == "Command-Return connects.")
        #expect(copy.commandReturnJoinHint == "Press ⌘↩ to join")
        #expect(copy.commandReturnJoinSpoken == "Press Command-Return to join.")
        #expect(copy.commandReturnJoinAccessibilityHint == "Command-Return joins.")

        let hints: [StageFooterSpec.CommandReturnHint] = [.install, .connect, .join]
        #expect(hints.map(\.shown) == [copy.commandReturnHint, copy.commandReturnConnectHint, copy.commandReturnJoinHint])
        #expect(hints.map(\.spoken) == [copy.commandReturnSpoken, copy.commandReturnConnectSpoken, copy.commandReturnJoinSpoken])
        // A primary that names no hint is the review's, which installs.
        #expect(StageFooterSpec.Primary(title: "Install 4 changes", key: .commandReturn) {}.commandReturnHint == .install)
    }

    /// Your other Macs, with an address typed: Connect and share ⌘↩ says
    /// connect, never install.
    @Test func connectAndShareSaysConnect() async throws {
        let stage = try await MacsStage.make()
        defer { stage.remove() }
        stage.model.update(address: stage.repository.address)

        let primary = try #require(LaunchpadStageView.footer(for: stage.flow).primary)
        #expect(primary.title == LaunchpadCopy.Macs.connectAndShare)
        #expect(primary.key == .commandReturn)
        #expect(primary.commandReturnHint == .connect)

        stage.flow.showCommandReturnHint()
        let footer = AccessibilityProbe(Self.footer(stage.flow), size: Self.footerSize)
        defer { footer.close() }
        #expect(footer.contains("Press ⌘↩ to connect"))
        #expect(!footer.contains("Press ⌘↩ to install"))
    }

    /// Join, before and once it can join: Join as Cedar ⌘↩ says join.
    @Test func joinSaysJoin() async throws {
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let (flow, _) = await cedar.joinStage()

        let primary = try #require(LaunchpadStageView.footer(for: flow).primary)
        #expect(primary.key == .commandReturn)
        #expect(primary.commandReturnHint == .join)

        flow.showCommandReturnHint()
        let footer = AccessibilityProbe(Self.footer(flow), size: Self.footerSize)
        defer { footer.close() }
        #expect(footer.contains("Press ⌘↩ to join"))
        #expect(!footer.contains("Press ⌘↩ to install"))
    }

    /// The keycaps that flash after a plain ↩ flash one way, from one
    /// helper: the stage's footer, its review panel and the shared review
    /// sheet all use `KeycapFlash`, and no copy of it lives anywhere else.
    @Test func oneKeycapFlashServesEveryPrimary() throws {
        let files = try PackageSourceFile.all(in: "AgentToolingApp")
        let declares = files.filter { $0.lines.contains { $0.contains("struct KeycapFlash: ViewModifier") } }.map(\.path)
        #expect(declares == ["Components+Keys.swift"])
        let users = Set(files.filter { $0.lines.contains { $0.contains(".modifier(KeycapFlash(") } }.map(\.path))
        #expect(
            users == ["Launchpad/Stage/StageFooterBar.swift", "Launchpad/Screens/LaunchpadReviewPanel.swift", "PlanReviewSheet.swift"])
        // A view modifier that dims what it wraps once per change is this one
        // helper, not a private copy of it.
        let copies = files.filter { file in
            file.path != "Components+Keys.swift" && file.lines.contains { $0.contains("dimmed ? Opacity.inactive : 1") }
        }
        #expect(copies.isEmpty, "\(copies.map(\.path))")
    }

    private static let footerSize = CGSize(width: WindowSize.stage.width, height: StageLayout.Grid.footerHeight)

    private static func footer(_ flow: LaunchpadFlow) -> some View {
        StageFooterBar(
            info: flow.info, spec: LaunchpadStageView.footer(for: flow), commandReturnHint: flow.commandReturnHint,
            flash: flow.commandReturnFlash)
    }
}

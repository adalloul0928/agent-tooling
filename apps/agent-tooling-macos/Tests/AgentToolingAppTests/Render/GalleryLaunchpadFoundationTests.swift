import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The setup stage's foundation in the gallery: every step's placeholder in
/// the stage's own window, FooterConfirm in each moment, the review panel, the
/// stage kit's pieces, and the token sheet the owner signs off (O5). The
/// screens each package builds replace the placeholders under their own
/// gallery suites.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad foundation", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadFoundationTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let flowSource = "Sources/AgentToolingApp/Launchpad/LaunchpadStageView.swift"

    @Test func placeholdersBeforeTheLibrary() async throws {
        for appearance in Self.both {
            let bundle = URL(filePath: "/private/var/folders/xy/AppTranslocation/Agent Tooling.app", directoryHint: .isDirectory)
            let moving = try await LaunchpadFixture(
                installation: AgentToolingInstallation(
                    bundleURL: bundle, location: .translocated(bundle),
                    mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil,
                    isAdHocSigned: false))
            defer { moving.remove() }
            try galleryStageSnapshot(
                moving.stage(moving.flow()), screen: "S00 Before you start", state: "placeholder", appearance: appearance,
                source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadMoveScreen.swift")

            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let flow = fixture.flow()
            let screens: [(LaunchpadStep, String, String)] = [
                (.welcome, "S01 Welcome", "LaunchpadWelcomeScreen.swift"),
                (.apps, "S02 Your apps", "LaunchpadTileSequenceScreen.swift"),
                (.reads, "S04 What Agent Tooling reads", "LaunchpadTileSequenceScreen.swift"),
            ]
            for (step, screen, file) in screens {
                #expect(flow.step == step)
                try galleryStageSnapshot(
                    fixture.stage(flow), screen: screen, state: "placeholder", appearance: appearance,
                    source: "Sources/AgentToolingApp/Launchpad/Screens/\(file)")
                if step != .reads { LaunchpadStageView.footer(for: flow).primary?.action() }
            }
            try galleryStageSnapshot(
                fixture.stage(fixture.flow(.finishJoin(WorkspaceObjectID()))), screen: "J01 Join", state: "placeholder",
                appearance: appearance, source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadJoinScreen.swift")
        }
    }

    @Test func placeholdersPastTheLibrary() async throws {
        let screens: [(LaunchpadStep, String, String)] = [
            (.found, "S06 Your library, as read", "LaunchpadTileSequenceScreen.swift"),
            (.library, "S08 Your library", "LaunchpadLibraryScreen.swift"),
            (.place, "S10 Put in apps", "LaunchpadPlaceScreen.swift"),
            (.ask, "S11 Let your apps ask", "LaunchpadAskScreen.swift"),
            (.assistant, "S15 Let your assistant help", "LaunchpadAssistantScreen.swift"),
            (.behave, "S16 How Agent Tooling behaves", "LaunchpadBehaveScreen.swift"),
            (.macs, "S17 Your other Macs", "LaunchpadMacsScreen.swift"),
            (.done, "S22 Done", "LaunchpadDoneScreen.swift"),
        ]
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await fixture.sample(.afterRead).workspace
            for (step, screen, file) in screens {
                try galleryStageSnapshot(
                    fixture.stage(fixture.flow(.continueFirstRun(step), workspace: workspace)), screen: screen,
                    state: "placeholder", appearance: appearance, source: "Sources/AgentToolingApp/Launchpad/Screens/\(file)")
            }
        }
    }

    @Test func youJoinedOnCedar() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture(.cedar)
            defer { fixture.remove() }
            let (flow, sample) = try await fixture.flow(at: .cedarJoined)
            defer { sample.remove() }
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "J02 You joined", state: "placeholder", appearance: appearance,
                source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadArrivalsScreen.swift")
        }
    }

    @Test func theReviewPanelOnJuniper() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let (flow, _) = try await fixture.flow(at: .afterAsk)
            LaunchpadStageView.footer(for: flow).primary?.action()
            let review = try #require(flow.presentedReview)
            await review.prepare()
            try galleryStageSnapshot(
                fixture.stage(flow), screen: "S12 Review", state: "placeholder, 5 listed, 4 run", appearance: appearance,
                source: "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadReviewPanel.swift")
        }
    }

    @Test func footerConfirmInEachMoment() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await fixture.sample(.afterRead).workspace
            let before = fixture.flow()
            before.requestClose()
            let after = fixture.flow(.continueFirstRun(.library), workspace: workspace)
            after.requestClose()
            let rerun = fixture.flow(.rerun, workspace: workspace)
            rerun.requestClose()
            let finishing = fixture.flow(.continueFirstRun(.macs), workspace: workspace)
            _ = finishing.model(for: .macs) { GalleryPublishing() }
            finishing.requestClose()
            for (flow, state) in [(before, "before the library"), (after, "after the library"), (rerun, "rerun"), (finishing, "finishing")]
            {
                try galleryStageSnapshot(
                    fixture.stage(flow), screen: "FooterConfirm", state: state, appearance: appearance,
                    source: "Sources/AgentToolingApp/Launchpad/Stage/StageFooterBar.swift")
            }
        }
    }

    @Test func theStageKit() throws {
        let sheets: [(String, AnyView)] = [
            ("poster", AnyView(KitSheet.poster)), ("tiles", AnyView(KitSheet.tiles)), ("manifest", AnyView(KitSheet.manifest)),
            ("cards and confirm", AnyView(KitSheet.cards)),
        ]
        for appearance in Self.both {
            for (state, sheet) in sheets {
                try galleryStageSnapshot(
                    sheet.environment(\.stageMotion, .still), screen: "Stage kit", state: state, appearance: appearance,
                    source: "Sources/AgentToolingApp/Launchpad/Stage")
            }
        }
    }

    /// O5: every token the stage adds, drawn, for the owner's sign-off.
    @Test func theTokenSheet() throws {
        for appearance in Self.both {
            try gallerySnapshot(
                TokenSheet().environment(\.stageMotion, .still), area: "Launchpad", screen: "Token sheet", state: "stage tokens",
                size: GallerySize.standard, appearance: appearance, source: "Sources/AgentToolingApp/DesignTokens.swift")
        }
    }
}

/// A publish under way, for FooterConfirm's finishing moment.
@MainActor
private final class GalleryPublishing: LaunchpadInterruptible {
    var interruption: LaunchpadInterruption { .finishing(LaunchpadCopy.Footer.publishing) }
    func interrupt() async {}
}

/// The stage's tokens on one page: its colours on the ground they are drawn
/// over, its sizes, type, strokes, elevations, opacities and motion.
private struct TokenSheet: View {
    var body: some View {
        ZStack {
            StageGround(opaque: true)
            HStack(alignment: .top, spacing: Space.huge) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    section("Ground, rim and well") {
                        swatches([
                            ("stageGround", AgentTheme.stageGround), ("stageGroundShade", AgentTheme.stageGroundShade),
                            ("stageGroundOpaque", AgentTheme.stageGroundOpaque), ("stageRimTop", AgentTheme.stageRimTop),
                            ("stageRimEdge", AgentTheme.stageRimEdge), ("wellFloor", AgentTheme.wellFloor),
                            ("wellFloorShade", AgentTheme.wellFloorShade), ("wellTopShade", AgentTheme.wellTopShade),
                            ("wellLip", AgentTheme.wellLip),
                        ])
                    }
                    section("Plates, sockets and scrim") {
                        swatches([
                            ("plateOnCard", AgentTheme.plateOnCard), ("tileTopEdge", AgentTheme.tileTopEdge),
                            ("tileSheen", AgentTheme.tileSheen), ("socketShade", AgentTheme.socketShade),
                            ("socketLip", AgentTheme.socketLip), ("graphiteDeep", AgentTheme.graphiteDeep),
                            ("stageScrim", AgentTheme.stageScrim),
                        ])
                    }
                    section("Shadow colours") {
                        swatches([
                            ("tileContactShadow", AgentTheme.tileContactShadow), ("tileCastShadow", AgentTheme.tileCastShadow),
                            ("markContactShadow", AgentTheme.markContactShadow), ("markCastShadow", AgentTheme.markCastShadow),
                            ("cardRestShadow", AgentTheme.cardRestShadow), ("smallMarkEdgeShadow", AgentTheme.smallMarkEdgeShadow),
                        ])
                    }
                }
                .frame(width: StageLayout.Grid.contentWidth / 2)
                VStack(alignment: .leading, spacing: Space.xl) {
                    section("Type") {
                        Text("AgentFont.hero · \(Int(AgentFont.heroSize)) pt semibold").font(AgentFont.hero)
                        Text("AgentFont.pageTitle · \(Int(AgentFont.pageTitleSize)) pt, for comparison").font(AgentFont.pageTitle)
                    }
                    section("Sizes and elevations") {
                        HStack(alignment: .bottom, spacing: Space.xl) {
                            labelled("heroMark \(Int(Size.heroMark))") { AgentToolingMark() }
                            labelled("stageTile \(Int(Size.stageTile)) · tileCast") {
                                StageAgentTile(client: .claude, state: .managed)
                                    .padding(Space.lg)
                                    .background { WellSurface() }
                            }
                            labelled("compact \(Int(Size.stageTileCompact))") {
                                StageAgentTile(client: .codex, state: .read, compact: true)
                            }
                            labelled("app mark \(Int(Size.tile)) · \(Int(Size.tileSmall))") {
                                HStack {
                                    AgentToolingAppMark()
                                    AgentToolingAppMark(size: Size.tileSmall)
                                }
                            }
                        }
                    }
                    section("Strokes, highlights and keycaps") {
                        HStack(spacing: Space.xl) {
                            labelled("Hairline.focus") {
                                RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(AgentTheme.selection, lineWidth: Hairline.focus)
                                    .frame(width: Size.stageTile, height: Size.controlHeight)
                            }
                            labelled("dash · dashedHairline") {
                                RoundedRectangle(cornerRadius: Radius.sm)
                                    .strokeBorder(
                                        Color.primary.opacity(Opacity.dashedHairline),
                                        style: StrokeStyle(lineWidth: Hairline.width, dash: Hairline.dash)
                                    )
                                    .frame(width: Size.stageTile, height: Size.controlHeight)
                            }
                            labelled("softHighlight") {
                                Text("Codex").padding(Space.sm).softHighlight(true)
                            }
                            labelled("keycaps · on the primary") {
                                HStack {
                                    KeyCombo([.escape])
                                    // A still capsule in the accent, not a button: an
                                    // off-screen window is never key, so a button would
                                    // draw inactive and hide the on-accent wash, stroke
                                    // and label the owner signs off.
                                    HStack(spacing: Space.sm) {
                                        Text("Install 4 changes")
                                            .font(AgentFont.bodyMedium)
                                            .foregroundStyle(AgentTheme.onSelection)
                                        KeyCombo([.command, .returnKey])
                                    }
                                    .environment(\.keycapOnAccent, true)
                                    .padding(.horizontal, Space.lg)
                                    .padding(.vertical, Space.xs)
                                    .background(AgentTheme.selection, in: Capsule())
                                }
                            }
                        }
                    }
                    section("A card on the stage") {
                        StageTwoColumnCard {
                            Text("stageCard · cardRest").padding(Space.lg)
                        } trailing: {
                            StepCapsules(reached: 3, total: 5).padding(Space.lg)
                        }
                        .frame(width: StageLayout.Grid.contentWidth / 2)
                    }
                    section("Motion and windows") {
                        Text(verbatim: Self.motion).font(AgentFont.caption).wrapsLines()
                        Text(verbatim: Self.windows).font(AgentFont.caption).wrapsLines()
                    }
                }
            }
            .padding(Space.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The stage's motion values, as their own numbers.
    private static var motion: String {
        let delays = AgentMotion.knobDelays.map { "\($0)" }.joined(separator: ", ")
        return [
            "revealStagger \(AgentMotion.revealStagger) s", "knobSlide 0.46 s snappy", "knobDelays \(delays) s",
            "heroDelay \(AgentMotion.heroDelay) s", "rowStagger \(AgentMotion.rowStagger) s, at most \(AgentMotion.rowStaggerCap) s",
            "columnStagger \(AgentMotion.columnStagger) s", "badgeDelay \(AgentMotion.badgeDelay) s",
            "panelRise \(AgentMotion.panelRise) pt", "cardRise \(AgentMotion.cardRise) pt",
        ].joined(separator: " · ")
    }

    /// The stage's window and sheet sizes.
    private static var windows: String {
        "WindowSize.stage \(Int(WindowSize.stage.width)) × \(Int(WindowSize.stage.height)) · "
            + "SheetSize.stageSheet \(Int(SheetSize.stageSheet.width)) × \(Int(SheetSize.stageSheet.height))"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Eyebrow(title)
            content()
        }
    }

    private func swatches(_ colours: [(String, Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Size.firstLaunchFormWidth / 3), alignment: .leading)], alignment: .leading) {
            ForEach(colours, id: \.0) { name, colour in
                HStack(spacing: Space.sm) {
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(colour)
                        .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(AgentTheme.hairline, lineWidth: Hairline.width) }
                        .frame(width: Size.stageTileCompact, height: Size.controlHeight)
                    Text(name).font(AgentFont.monoMicro)
                }
            }
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: Space.sm) {
            content()
            Text(label).font(AgentFont.micro).foregroundStyle(.secondary)
        }
    }
}

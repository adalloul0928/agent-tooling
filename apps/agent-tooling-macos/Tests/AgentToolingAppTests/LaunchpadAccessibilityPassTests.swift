import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Exercises setup through accessibility presses. Verifies title/footer groups,
/// keycap exclusion, reduced-motion transitions, opaque reduced-transparency
/// backgrounds and 3:1 contrast for hairlines. Uses synthetic client homes.
@Suite("Launchpad · accessibility pass", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadAccessibilityPassTests {
    // MARK: - VoiceOver

    /// Start here, every default taken, pressed through VoiceOver's press from
    /// Welcome to Done's Go to Home: Install 3 changes in the review panel,
    /// sharing skipped.
    @Test func voiceOverCompletesTheStartHereWalk() async throws {
        let stage = try await EndToEndStage.juniper()
        defer { stage.remove() }
        let flow = stage.flow
        let probe = AccessibilityProbe(
            stage.fixture.stage(flow)
                .environment(\.launchpadLibraryServices, LaunchpadLibraryAdditionsTests.services(fetches: LibraryFetchLog())),
            size: WindowSize.stage)
        defer { probe.close() }

        try Self.hear(probe, title: "Welcome to Agent Tooling", primary: "Start here")
        try Self.press(probe, "Start here")
        #expect(flow.step == .apps)

        try Self.hear(probe, eyebrow: "Your coding agents", title: "Choose the apps this Mac manages", primary: "Manage 3 apps")
        // S02: the tile row in one sentence, and each tile a toggle that says
        // where its app was found.
        let detection = LaunchpadDetection.of(flow)
        #expect(probe.elements.contains { $0.label == detection.rowSummary }, "S02 does not read \(detection.rowSummary)")
        let codexTile = detection.tileLabel(.codex, managed: true)
        #expect(
            probe.elements.contains { $0.role == .checkBox && $0.label == codexTile }, "S02 has no toggle read as \(codexTile)")
        try Self.press(probe, "Manage 3 apps")
        #expect(flow.step == .reads)

        try Self.hear(
            probe, eyebrow: "Before anything is read", title: "Agent Tooling looks before it changes anything", primary: "Continue")
        try Self.press(probe, "Continue")
        let read = LaunchpadTileSequenceScreen.read(flow)
        await waitUntil { read.phase == .finished || read.failure != nil }
        #expect(read.phase == .finished)
        await waitUntil { LaunchpadStageView.footer(for: flow).primary?.isEnabled == true }
        probe.settle()
        try Self.hear(probe, title: "Reading what each app holds", primary: "Continue")
        // S05: one list per app, read with its counts.
        let manifest = try #require(read.manifest)
        for app in manifest.apps {
            let list = LaunchpadReadSession.manifestSummary(of: app, home: flow.environment.homeURL)
            #expect(probe.elements.contains { $0.label == list }, "S05 does not read \(list)")
        }
        try Self.press(probe, "Continue")
        await waitUntil { flow.step == .found }

        try Self.hear(probe, eyebrow: "Your library", title: "Here is what this Mac has", primary: "Continue")
        // The list's own heading reads its count, not the dot drawn before it.
        #expect(probe.elements.contains { $0.role == Self.heading && $0.label == "In your library, 8 entries" })
        try Self.press(probe, "Continue")
        #expect(flow.step == .library)

        let library = LaunchpadLibraryAdditions.of(flow)
        await waitUntil { library.phase == .ready }
        probe.settle()
        try Self.hear(probe, eyebrow: "Your library", title: "Start your library", primary: "Continue")
        try Self.press(probe, "Continue")
        await waitUntil { flow.step != .library }
        #expect(flow.step == .place)

        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await waitUntil { placement.phase == .ready }
        probe.settle()
        try Self.hear(probe, eyebrow: "Put in apps", title: "Put your tools in your apps", primary: "Continue")
        // Every default taken places nothing, so this grid has no cells;
        // `voiceOverReadsTheGridsCells` hears them on the sample world's.
        #expect(placement.items.isEmpty)
        try Self.press(probe, "Continue")
        await waitUntil { flow.step != .place }
        #expect(flow.step == .ask)

        await waitUntil { LaunchpadStageView.footer(for: flow).primary?.title == "Review 3 changes…" }
        probe.settle()
        try Self.hear(probe, eyebrow: "Put in apps", title: "Let your apps ask Agent Tooling", primary: "Review 3 changes…")
        try Self.press(probe, "Review 3 changes…")
        await waitUntil { flow.presentedReview != nil }
        let review = try #require(flow.presentedReview)
        await waitUntil { review.phase == .ready }
        probe.settle()

        // The panel is modal: its own title and bar, nothing of the screen
        // under it, and no footer.
        try Self.hear(probe, title: "Install 3 changes", primary: "Install 3 changes", footer: false)
        #expect(!probe.contains("Let your apps ask Agent Tooling"), "the screen under the panel is still read")
        // S12: each step read with its number, what it does and what it runs.
        let step = try #require(review.groups.flatMap(\.steps).first { $0.number != nil })
        let stepLabel = review.accessibilityLabel(for: step)
        #expect(stepLabel.hasPrefix("Step 1 of "), "the first step reads \(stepLabel)")
        #expect(probe.elements.contains { $0.label == stepLabel }, "S12 does not read \(stepLabel)")
        let workspace = try #require(flow.workspace)
        let apps: Set<ClientKind> = [.codex, .claude, .gemini]
        stage.fixture.scriptReviewCommands(in: workspace, runner: stage.helperRunner(for: apps))
        stage.fixture.observer.answer(with: try await stage.fixture.endToEndObservations(afterConnecting: apps))
        try Self.press(probe, "Install 3 changes")
        await waitUntil { flow.outcomes.install != nil }
        await waitUntil {
            if case .finished = review.phase { return true }
            return false
        }
        probe.settle()
        try Self.press(probe, LaunchpadCopy.Footer.continue)
        await waitUntil { flow.presentedReview == nil && flow.step == .assistant }

        try Self.hear(probe, eyebrow: "Preferences", title: "Let your assistant help", primary: "Continue")
        try Self.press(probe, "Continue")
        await waitUntil { flow.step == .behave }

        try Self.hear(probe, eyebrow: "Preferences", title: "How Agent Tooling behaves", primary: "Continue")
        try Self.press(probe, "Continue")
        await waitUntil { flow.step == .macs }

        try Self.hear(probe, eyebrow: "Other Macs", title: "Use your library on your other Macs", primary: "Skip for now")
        try Self.press(probe, "Skip for now")
        await waitUntil { flow.step == .done }

        let done = LaunchpadDoneScreen.model(flow)
        await waitUntil { done.auditSettled }
        probe.settle()
        try Self.hear(probe, title: "Set up, with 2 things left", primary: "Go to Home")
        try Self.press(probe, "Go to Home")
        await waitUntil { flow.pendingHandOff != nil }
        #expect(flow.pendingHandOff == .overview)
    }

    /// S10's grid on the sample world's library, with Release Notes and
    /// Frontend Design made yours and Supabase added: VoiceOver hears each
    /// cell as the model says it, its item, its app and what happens there.
    @Test func voiceOverReadsTheGridsCells() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterLibrary)
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        let probe = AccessibilityProbe(fixture.stage(flow), size: WindowSize.stage)
        defer { probe.close() }

        try Self.hear(probe, eyebrow: "Put in apps", title: "Put your tools in your apps", primary: "Continue")
        let item = try #require(placement.items.first)
        for app in [ClientKind.codex, .claude, .gemini] {
            let cell = placement.accessibilityLabel(for: LaunchpadPlacement.Key(item: item.artifactID, app: app))
            // A cell that cannot be toggled is static text, read from its value.
            #expect(probe.contains(cell), "S10 does not read \(cell)")
        }
    }

    /// S06's list heading as VoiceOver reads it: the count with the noun
    /// Done counts the same rows by (NEW spoken copy, owner flag O6).
    @Test func theListHeadingIsReadWithItsNoun() {
        #expect(LaunchpadCopy.Found.listHeadingSpoken(8) == "In your library, 8 entries")
        #expect(LaunchpadCopy.Found.listHeadingSpoken(1) == "In your library, 1 entry")
    }

    // MARK: - Reduce Motion

    /// Under Reduce Motion the stage runs no detail motion (no slide,
    /// stagger, scale, bounce or draw-on) and changes content with `quick`'s
    /// crossfade; a still render stays still either way.
    @Test func reduceMotionResolvesTheStagesMotion() {
        #expect(StageMotion.full.resolved(reduceMotion: true) == .reduced)
        #expect(StageMotion.full.resolved(reduceMotion: false) == .full)
        #expect(StageMotion.still.resolved(reduceMotion: true) == .still)
        #expect(!StageMotion.reduced.animatesDetails)
        #expect(StageMotion.full.animatesDetails)
        #expect(StageMotion.reduced.contentChange == AgentMotion.quick)
        #expect(StageMotion.full.contentChange == AgentMotion.selection)
        #expect(StageMotion.still.contentChange == nil)
    }

    /// Every stage file that animates asks for Reduce Motion, through the
    /// system's setting or the stage's resolved motion. The hand-off's fade
    /// is the one exception: it is the crossfade Reduce Motion keeps.
    @Test func everyStageFileThatAnimatesAsksForReduceMotion() throws {
        let animates = ["withAnimation(", ".animation(", ".transition(", "symbolEffect", "contentTransition"]
        let asks = ["accessibilityReduceMotion", "stageMotion", "reduceMotion"]
        let crossfadeOnly: Set<String> = ["Launchpad/SetupStageWindow.swift"]
        let files = try PackageSourceFile.all(in: "AgentToolingApp").filter {
            $0.path.hasPrefix("Launchpad/") || $0.path == "Components+Stage.swift" || $0.path.hasPrefix("FinishSetup")
        }
        #expect(files.count > 40, "the scan found too few files to mean anything: \(files.count)")
        var animating = 0
        for file in files where !crossfadeOnly.contains(file.path) {
            let text = file.lines.joined(separator: "\n")
            guard animates.contains(where: text.contains) else { continue }
            animating += 1
            #expect(asks.contains(where: text.contains), "\(file.path) animates without asking for Reduce Motion")
        }
        #expect(animating > 10, "the scan found too few animating files to mean anything: \(animating)")
    }

    // MARK: - Reduce Transparency

    /// Under Reduce Transparency the stage's ground is opaque, over no
    /// window material; otherwise it is the translucent face over it.
    @Test(arguments: [RenderAppearance.light, .dark])
    func reduceTransparencyMakesTheGroundOpaque(appearance: RenderAppearance) throws {
        let point = CGPoint(x: WindowSize.stage.width / 2, y: WindowSize.stage.height / 2)
        let normal = try Self.pixel(Self.emptyStage, at: point, size: WindowSize.stage, appearance: appearance)
        let reduced = try Self.pixel(
            Self.emptyStage.environment(\._accessibilityReduceTransparency, true), at: point, size: WindowSize.stage,
            appearance: appearance)
        let opaque = try Self.pixel(StageGround(opaque: true), at: point, size: WindowSize.stage, appearance: appearance)
        let translucent = try Self.pixel(StageGround(opaque: false), at: point, size: WindowSize.stage, appearance: appearance)
        #expect(reduced.alphaComponent == 1, "the ground lets the desktop through under Reduce Transparency")
        #expect(Self.same(reduced, opaque), "the ground is not the opaque ground: \(reduced) against \(opaque)")
        #expect(Self.same(normal, translucent), "the ground is not the translucent ground: \(normal) against \(translucent)")
        if appearance == .light {
            // Off screen the window material has no desktop to show, so in
            // dark the two grounds come out within a step of each other; in
            // light they part, which is what makes this check mean something.
            #expect(!Self.same(opaque, translucent), "the two grounds draw alike: \(opaque) against \(translucent)")
        }
    }

    // MARK: - Increase Contrast

    /// Under Increase Contrast every hairline and every resting edge on the
    /// stage reaches 3:1 against the ground it sits on, in both appearances:
    /// a card, Home's ground and the stage's own. As drawn they are a faint
    /// lift, well under that. The absent ring's grey keeps 3:1 as drawn and
    /// takes the stronger secondary label colour. (How macOS draws its own
    /// controls under the real setting is a person's check on a running Mac.)
    @Test(arguments: [RenderAppearance.light, .dark])
    func edgesReachThreeToOneUnderIncreaseContrast(appearance: RenderAppearance) throws {
        let edges: [(String, HairlineStyle)] = [
            ("a divider", HairlineStyle()),
            ("a card's edge", HairlineStyle(base: AgentTheme.hairlineStroke)),
            ("a stage field's edge", HairlineStyle(base: AgentTheme.stageFieldEdge)),
            ("a radio button's ring", HairlineStyle(base: AgentTheme.stageRadioRing)),
            ("the review well's dashed edge", HairlineStyle(base: Color.primary.opacity(Opacity.dashedHairline))),
        ]
        for (groundName, ground) in Self.grounds {
            for (edge, style) in edges {
                let drawn = try Self.contrast(of: style, on: ground, appearance: appearance, contrast: .standard)
                let increased = try Self.contrast(of: style, on: ground, appearance: appearance, contrast: .increased)
                #expect(increased >= 3, "\(edge) on \(groundName) reaches \(increased):1 under Increase Contrast")
                #expect(drawn < 3, "\(edge) on \(groundName) is already \(drawn):1, so the check means nothing")
            }
            let ring = try Self.contrast(of: AbsentRingStyle(), on: ground, appearance: appearance, contrast: .standard)
            let ringIncreased = try Self.contrast(of: AbsentRingStyle(), on: ground, appearance: appearance, contrast: .increased)
            #expect(ring >= 3, "the absent ring on \(groundName) is \(ring):1")
            #expect(ringIncreased > ring, "the absent ring on \(groundName) is no stronger: \(ringIncreased):1")
        }
    }

    /// A stage field (S17, J01) draws that edge itself: under Increase
    /// Contrast its resting edge keeps 3:1 against its own face and against
    /// the card around it.
    @Test(arguments: [RenderAppearance.light, .dark])
    func aStageFieldsEdgeReachesThreeToOne(appearance: RenderAppearance) throws {
        let size = CGSize(width: 240, height: Size.controlHeight + 2 * Space.md)
        let field = ZStack {
            AgentTheme.controlBackground
            StageField(label: LaunchpadCopy.Macs.addressLabel, text: .constant("")).padding(Space.md)
        }
        let middle = size.width / 2
        for (contrast, least) in [(ColorSchemeContrast.standard, 1.0), (.increased, 3.0)] {
            let bitmap = try rasterize(field.environment(\._colorSchemeContrast, contrast), size: size, appearance: appearance)
            let edge = try Self.sample(bitmap, at: CGPoint(x: middle, y: Space.md + Hairline.width / 2), size: size)
            let face = try Self.sample(bitmap, at: CGPoint(x: middle, y: size.height / 2), size: size)
            let card = try Self.sample(bitmap, at: CGPoint(x: middle, y: Space.md / 2), size: size)
            let againstFace = Self.ratio(edge, face)
            let againstCard = Self.ratio(edge, card)
            #expect(
                min(againstFace, againstCard) >= least, "the field's edge is \(againstFace):1 on its face, \(againstCard):1 on the card")
            if contrast == .standard {
                #expect(max(againstFace, againstCard) < 3, "the field's edge already reaches 3:1, so the check means nothing")
            }
        }
    }

    /// The divider every card and row draws is that hairline: the theme's as
    /// drawn, the stronger one under Increase Contrast.
    @Test func theDividerIsTheContrastAwareHairline() throws {
        let size = CGSize(width: 40, height: 1)
        let middle = CGPoint(x: 20, y: 0.5)
        let line = Hairline().frame(width: size.width)
        let standard = try Self.pixel(line, at: middle, size: size)
        let increased = try Self.pixel(line.environment(\._colorSchemeContrast, .increased), at: middle, size: size)
        #expect(Self.same(standard, try Self.pixel(Rectangle().fill(AgentTheme.hairline), at: middle, size: size)))
        #expect(Self.same(increased, try Self.pixel(Rectangle().fill(AgentTheme.hairlineIncreased), at: middle, size: size)))
    }

    /// The soft highlight's ring goes to full strength, and the absent ring
    /// to the secondary label colour.
    @Test(arguments: [RenderAppearance.light, .dark])
    func theRingsStrengthenUnderIncreaseContrast(appearance: RenderAppearance) throws {
        let side = Size.stageTile
        let size = CGSize(width: side, height: side)
        let edge = CGPoint(x: side / 2, y: Hairline.ring / 2)
        let highlight = Color.clear.frame(width: side, height: side).softHighlight(true)
        let standardRing = try Self.pixel(highlight, at: edge, size: size, appearance: appearance)
        let increasedRing = try Self.pixel(
            highlight.environment(\._colorSchemeContrast, .increased), at: edge, size: size, appearance: appearance)
        #expect(
            increasedRing.alphaComponent > standardRing.alphaComponent,
            "the soft highlight's ring is no stronger: \(increasedRing) against \(standardRing)")

        let stroke = Space.md
        let ring = AbsentMark(size: side, lineWidth: stroke, inset: 0)
        let top = CGPoint(x: side / 2, y: stroke / 2)
        let absent = try Self.pixel(ring, at: top, size: size, appearance: appearance)
        let increasedAbsent = try Self.pixel(
            ring.environment(\._colorSchemeContrast, .increased), at: top, size: size, appearance: appearance)
        let grey = Circle().strokeBorder(AgentTheme.absentMark, lineWidth: stroke)
        // The secondary label colour as SwiftUI draws it under Increase
        // Contrast, which is itself stronger than under the standard one.
        let secondary = Circle().strokeBorder(Color.secondary, lineWidth: stroke)
            .environment(\._colorSchemeContrast, .increased)
        #expect(Self.same(absent, try Self.pixel(grey, at: top, size: size, appearance: appearance)))
        #expect(
            Self.same(increasedAbsent, try Self.pixel(secondary, at: top, size: size, appearance: appearance)),
            "the absent ring is not the secondary label colour: \(increasedAbsent)")
        #expect(!Self.same(increasedAbsent, absent), "the absent ring does not change under Increase Contrast")
    }

    // MARK: - Helpers

    /// What VoiceOver finds on the stage: one heading, the screen's title,
    /// with the eyebrow read just before it; the primary as a labelled,
    /// usable button, inside the footer's group of actions (the review
    /// panel's bar has none); every button named; and no keycap.
    private static func hear(
        _ probe: AccessibilityProbe, eyebrow: String? = nil, title: String, primary: String, footer: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let elements = probe.elements
        let headings = elements.enumerated().filter { $0.element.role == heading }
        let first = try #require(headings.first, "no heading on \(title)", sourceLocation: sourceLocation)
        #expect(first.element.label == title, "the first heading reads \(first.element.label)", sourceLocation: sourceLocation)
        #expect(
            headings.filter { $0.element.label == title }.count == 1, "\(title) is heard more than once",
            sourceLocation: sourceLocation)
        if let eyebrow {
            let said = elements.prefix(first.offset).last { $0.role == .staticText }
            let words = said.map { $0.value ?? $0.label } ?? "nothing"
            #expect(
                words.localizedCaseInsensitiveCompare(eyebrow) == .orderedSame,
                "\(title)'s eyebrow is not read just before it: \(words)", sourceLocation: sourceLocation)
        }
        let button = try #require(
            elements.first { $0.role == .button && $0.label == primary }, "no \(primary) on \(title)",
            sourceLocation: sourceLocation)
        #expect(button.isEnabled, "\(primary) cannot be pressed on \(title)", sourceLocation: sourceLocation)
        let actions = elements.contains { $0.role == .group && $0.label == LaunchpadCopy.Footer.groupLabel }
        #expect(
            actions == footer, footer ? "\(title) has no footer group of actions" : "the footer is read under the panel",
            sourceLocation: sourceLocation)
        for element in elements where element.role == .button {
            #expect(!element.label.isEmpty, "an unnamed button on \(title)", sourceLocation: sourceLocation)
        }
        for element in elements {
            let said = [element.label, element.value ?? ""]
            #expect(
                !said.contains { words in words.contains(where: keycapGlyphs.contains) || keycapWords.contains(words) },
                "a keycap is read on \(title): \(said)", sourceLocation: sourceLocation)
            #expect(
                !element.label.contains(", ·"), "a separator is read as a word on \(title): \(element.label)",
                sourceLocation: sourceLocation)
        }
    }

    /// Presses `label` as VoiceOver's press does, and says so if it could not.
    private static func press(_ probe: AccessibilityProbe, _ label: String, sourceLocation: SourceLocation = #_sourceLocation)
        throws
    {
        try #require(probe.press(label), "VoiceOver could not press \(label)", sourceLocation: sourceLocation)
    }

    private static let heading = NSAccessibility.Role(rawValue: "AXHeading")
    /// What a keycap draws, which VoiceOver must never read: one of these
    /// glyphs anywhere in what it hears, or a key's word said on its own.
    private static let keycapGlyphs: Set<Character> = ["⌘", "↩", "⎋", "⇧", "⌥", "⌃"]
    private static let keycapWords: Set<String> = ["esc", "["]

    private static var emptyStage: some View {
        SetupStage {
            Color.clear
        } footer: {
            Color.clear
        } overlay: {
            EmptyView()
        }
    }

    /// The colour `view` draws at `point`, in points from its top left, at
    /// `size`.
    private static func pixel(
        _ view: some View, at point: CGPoint = CGPoint(x: 20, y: 20), size: CGSize = CGSize(width: 40, height: 40),
        appearance: RenderAppearance = .light
    ) throws -> NSColor {
        try sample(rasterize(view, size: size, appearance: appearance), at: point, size: size)
    }

    private static func sample(_ bitmap: NSBitmapImageRep, at point: CGPoint, size: CGSize) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let colour = bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
        return try #require(colour, "nothing drawn at \(point)")
    }

    /// The grounds an edge on the stage sits on: a card, Home's ground and
    /// the stage's own.
    private static let grounds: [(String, Color)] = [
        ("a card", AgentTheme.controlBackground), ("Home's ground", AgentTheme.contentBackground),
        ("the stage's ground", AgentTheme.stageGroundOpaque),
    ]

    /// How far `style` stands out from `ground` when drawn over it, as a
    /// contrast ratio: the top half of a swatch is the ground, the bottom
    /// half the style over it.
    private static func contrast(
        of style: some ShapeStyle, on ground: Color, appearance: RenderAppearance, contrast: ColorSchemeContrast
    ) throws -> Double {
        let size = CGSize(width: 40, height: 40)
        let swatch = ZStack(alignment: .bottom) {
            ground
            Rectangle().fill(style).frame(height: size.height / 2)
        }
        .environment(\._colorSchemeContrast, contrast)
        let bitmap = try rasterize(swatch, size: size, appearance: appearance)
        let under = try sample(bitmap, at: CGPoint(x: size.width / 2, y: size.height / 4), size: size)
        let over = try sample(bitmap, at: CGPoint(x: size.width / 2, y: size.height * 3 / 4), size: size)
        return ratio(over, under)
    }

    /// The contrast ratio of two opaque colours (WCAG 2's relative luminance).
    private static func ratio(_ one: NSColor, _ other: NSColor) -> Double {
        func luminance(_ colour: NSColor) -> Double {
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(colour.redComponent) + 0.7152 * linear(colour.greenComponent)
                + 0.0722 * linear(colour.blueComponent)
        }
        let (lighter, darker) = (max(luminance(one), luminance(other)), min(luminance(one), luminance(other)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Two colours within a rounding step of each other.
    private static func same(_ one: NSColor, _ other: NSColor) -> Bool {
        let step = 2.0 / 255
        return abs(one.redComponent - other.redComponent) <= step && abs(one.greenComponent - other.greenComponent) <= step
            && abs(one.blueComponent - other.blueComponent) <= step && abs(one.alphaComponent - other.alphaComponent) <= step
    }
}

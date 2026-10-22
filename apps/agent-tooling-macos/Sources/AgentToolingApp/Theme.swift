import AppKit
import SwiftUI

/// Page headings, filters, and content share one leading edge.
enum WorkspaceLayout {
    static let pageInset = Space.xxxl
    static let contentTopInset = Space.lg
    static let sectionSpacing = Space.xxxl
    /// The inset of a sheet's body and an inspector's detail pane.
    static let paneInset = Space.xxl
    /// How far a bar floating over a collection (the selection bar) sits above
    /// the window's bottom edge: the page inset and ten points more.
    static let floatingBarInset = pageInset + 10
}

/// Content uses neutral surfaces. NavigationSplitView owns the window's native
/// Liquid Glass sidebar, geometry, and active/inactive material behavior.
enum AgentTheme {
    /// The one accent: selection fills, prominent buttons, links, progress.
    static let selection = dynamic(light: 0x0065D1, dark: 0x0A64CD)

    /// The foreground on a selected row, where the accent fill is the ground.
    /// The system's text colour for an alternate selection adapts with the
    /// accent and the appearance, so it stays legible where a flat white would
    /// not.
    static let onSelection = Color(nsColor: .alternateSelectedControlTextColor)

    /// The ring an app leaves in a row of client marks when it does not have
    /// the item (`AbsentMark`). A mid grey that keeps at least 3:1 against a
    /// card, the contrast a graphic needs to be read (WCAG 1.4.11), in both
    /// appearances, while staying quieter than the brand marks beside it. On
    /// a selected row the ring is drawn from `onSelection` instead, since this
    /// grey reaches under 2:1 on the accent fill.
    static let absentMark = dynamic(light: 0x7C7C80, dark: 0x8E8E93)

    static let panelCornerRadius = Radius.lg

    /// Neutral content surfaces leave the desktop's color to the native glass.
    static let contentBackground = dynamic(light: 0xF5F5F7, dark: 0x1C1C1E)
    static let controlBackground = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let separator = Color(nsColor: .separatorColor)

    // Neutral graphite remains for objects outside the identity vocabulary.
    static let graphite = dynamic(light: 0x6E6E73, dark: 0xAEAEB2)

    // The identity palette: each tooling kind owns one hue, used as a filled
    // tile behind a white symbol. Rows across every screen share this language,
    // so a person can tell a skill from a server before reading a word.
    static let skill = dynamic(light: 0x16A34A, dark: 0x28C063)
    static let plugin = dynamic(light: 0xA21CAF, dark: 0xC33ED1)
    static let mcpServer = dynamic(light: 0x4F46E5, dark: 0x6C64F2)
    static let profile = dynamic(light: 0x7C3AED, dark: 0x9B67F5)

    /// The canvas: a faint blush-to-lavender wash shared by every screen. The
    /// stops are deliberately translucent — most of what you see is the
    /// behind-window material, the desktop blurred — with just enough tint to
    /// warm it. Home and the content screens sit on one continuous ground.
    static var canvasGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: dynamic(light: 0xF9E4EF, dark: 0x261B2E, lightAlpha: 0.38, darkAlpha: 0.46), location: 0),
                .init(color: dynamic(light: 0xEDE2F8, dark: 0x201D31, lightAlpha: 0.36, darkAlpha: 0.46), location: 0.45),
                .init(color: dynamic(light: 0xE3E8FB, dark: 0x1B2030, lightAlpha: 0.38, darkAlpha: 0.46), location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Status. Only ever a small glyph next to words.
    static let ok = dynamic(light: 0x2EA44F, dark: 0x3BD160)
    static let warning = dynamic(light: 0xDB8B00, dark: 0xFFB224)
    static let failure = dynamic(light: 0xDE4A3F, dark: 0xFF5C54)

    /// A colour that takes one value in light and another in dark. Internal,
    /// so an area that needs a colour of its own declares it in its own
    /// `extension AgentTheme` with the same recipe.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

// MARK: - The setup stage

/// The setup stage's material layer: a near-black ground in dark and the card
/// recipe in light, a recessed well the app tiles stand in, lit plates one
/// step above a card, sockets for the apps not found, and the shadows that
/// make them read as lit from above. The icon blue never becomes one of
/// these: it lives only inside Agent Tooling's mark.
extension AgentTheme {
    /// The stage's ground, laid over the behind-window material. In dark it
    /// is `contentBackground` at 96%, under `stageGroundShade`: about #151517.
    /// In light it is the card recipe, a near-white brightening.
    static let stageGround = dynamic(light: 0xFBFBFB, dark: 0x1C1C1E, lightAlpha: 0.93, darkAlpha: 0.96)
    /// The shadow colour the dark ground is deepened under; nothing in light.
    static let stageGroundShade = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0, darkAlpha: 0.30)
    /// The ground under Reduce Transparency: the same face, opaque. Dark
    /// still takes `stageGroundShade` over it.
    static let stageGroundOpaque = contentBackground
    /// The stage rim: a lit top edge and the line around it.
    static let stageRimTop = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.12)
    static let stageRimEdge = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

    /// The hero well's floor: below the stage ground, so what stands in it
    /// reads as lit. A faint fill in light; near-black in dark, deepened at
    /// the top by `wellFloorShade`.
    static let wellFloor = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.042, darkAlpha: 0.30)
    static let wellFloorShade = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0, darkAlpha: 0.12)
    /// The shade cast into the well from its top edge, and the light its lower
    /// lip catches.
    static let wellTopShade = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.45)
    static let wellLip = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.8, darkAlpha: 0.05)

    /// A lit tile's plate: one step above a card's, so a tile and a disc keep
    /// their plate on a card.
    static let plateOnCard = dynamic(light: 0xFFFFFF, dark: 0x3A3A3C)
    /// A lit tile's top edge catching the light, and the sheen that fades
    /// down its plate. Both are dark-only.
    static let tileTopEdge = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0, darkAlpha: 0.22)
    static let tileSheen = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0, darkAlpha: 0.098)
    /// A socket in the well's floor, where an app that was not found would
    /// stand: the shade under its top edge and the light on its lower one.
    static let socketShade = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.09, darkAlpha: 0.65)
    static let socketLip = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.9, darkAlpha: 0.07)

    /// A graphite deep enough to keep 4.5:1 behind a white symbol in dark, for
    /// the stage's symbol tiles. Light keeps `graphite`'s face.
    static let graphiteDeep = dynamic(light: 0x6E6E73, dark: 0x636366)
    /// The dimming under the stage's review panel: 22% in dark, 12% in light,
    /// where 22% greys a light stage into a mat.
    static let stageScrim = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.22)

    // The shadow colours behind `Elevation`'s stage shadows.
    static let tileContactShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.6)
    static let tileCastShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.26, darkAlpha: 0.8)
    static let markContactShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.18, darkAlpha: 0.5)
    static let markCastShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.6)
    static let cardRestShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0)
    static let smallMarkEdgeShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.28, darkAlpha: 0)
}

/// A deliberately small motion vocabulary. Short, transform-only animations
/// keep navigation legible without making data-heavy screens feel delayed.
///
/// The setup stage adds its own beats below. The one single motion longer
/// than `selection` is the knob slide on Welcome; every other sequence is
/// `selection`-length transitions staggered a few hundredths apart. Under
/// Reduce Motion none of them run: content crossfades at `quick`.
enum AgentMotion {
    static let selection = Animation.snappy(duration: 0.22, extraBounce: 0)
    static let quick = Animation.easeOut(duration: 0.12)
    /// The selection bar arriving over a list, and the list making room for it.
    static let actionBar = Animation.snappy(duration: 0.18)
    /// The scale a row of controls grows from as it fades in, so it settles
    /// into place rather than popping.
    static let appearScale: CGFloat = 0.98

    /// Between one tile lighting and the next, or one check drawing on and
    /// the next.
    static let revealStagger: Double = 0.07
    /// Agent Tooling's mark settling its three knobs on Welcome: the one
    /// single motion in the stage longer than `selection`.
    static let knobSlide = Animation.snappy(duration: 0.46)
    /// When each of the three knobs starts its slide.
    static let knobDelays: [Double] = [0.12, 0.19, 0.26]
    /// When Welcome's title arrives, after the first knob.
    static let heroDelay: Double = 0.30
    /// Between one list row arriving and the next, and the most a list's last
    /// row waits.
    static let rowStagger: Double = 0.02
    static let rowStaggerCap: Double = 0.16
    /// Between one manifest column, or one arrival, and the next.
    static let columnStagger: Double = 0.04
    /// A badge lands one beat after its tile lights.
    static let badgeDelay: Double = 0.12
    /// How far the review panel rises as it arrives, and a result card.
    static let panelRise: CGFloat = 12
    static let cardRise: CGFloat = 8
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Supplies the desktop backdrop underneath the entire split view. The native
/// NSGlassEffectView remains above this view and owns the sidebar's contents.
/// Keeping this outside the sidebar prevents legacy vibrancy from covering glass.
///
/// The material is `.sidebar`, deliberately: it is the same bright,
/// desktop-tinted glass the sidebar column shows, so the ground under the
/// content column and the ground under the sidebar are one color instead of
/// two. `.underWindowBackground` looked flat and gray beside it.
struct WindowBackdropMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Configures window identity and transparent title bars without replacing
/// SwiftUI's delegate. Setup disables zoom, full screen, and tabs; its close
/// button requests confirmation while programmatic dismissal still works.
/// Key tracking includes sheets and child windows. Reapply configuration because
/// SwiftUI may rebuild title-bar buttons.
/// Scratch runs disable frame and split-view autosave. Frames read before
/// configuration and system panel preferences can still come from the app domain.
struct WindowConfigurator: NSViewRepresentable {
    var role: AppWindow = .main
    /// Whether AppKit may keep this window's frame and its split views'
    /// dividers in the app's own defaults.
    var savesFrames = true
    var onCloseButton: (@MainActor () -> Void)?
    var onKeyChange: (@MainActor (Bool) -> Void)?
    var onWindowClosed: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = WindowConfigurationView()
        view.update(
            role: role, savesFrames: savesFrames, onCloseButton: onCloseButton,
            onKeyChange: onKeyChange, onWindowClosed: onWindowClosed)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowConfigurationView else { return }
        view.update(
            role: role, savesFrames: savesFrames, onCloseButton: onCloseButton,
            onKeyChange: onKeyChange, onWindowClosed: onWindowClosed)
        view.configureWindow()
    }
}

private final class WindowConfigurationView: NSView {
    private var role = AppWindow.main
    private var savesFrames = true
    private var onCloseButton: (@MainActor () -> Void)?
    private var onKeyChange: (@MainActor (Bool) -> Void)?
    private var onWindowClosed: (@MainActor () -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var keyObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var autosaveObservers: [NSObjectProtocol] = []
    private weak var unsavedWindow: NSWindow?

    func update(
        role: AppWindow, savesFrames: Bool, onCloseButton: (@MainActor () -> Void)?,
        onKeyChange: (@MainActor (Bool) -> Void)?, onWindowClosed: (@MainActor () -> Void)?
    ) {
        self.role = role
        self.savesFrames = savesFrames
        self.onCloseButton = onCloseButton
        self.onKeyChange = onKeyChange
        self.onWindowClosed = onWindowClosed
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObservingKey()
            stopObservingAutosave()
        }
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        window.identifier = role.identifier
        // The scene supplies a clear backing. The native material, rather than
        // an opaque window fill, determines the sidebar's appearance.
        window.isOpaque = false
        // The titlebar is part of the same canvas, not a strip of its own: the
        // content's ground runs to the top edge and the toolbar sits on it.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if !savesFrames { keepFramesOutOfDefaults(window) }
        guard role == .setup else { return }
        // The stage is a fixed 860 × 640: no zoom, no full screen, no tabs.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
        // The red button asks before the stage closes, as ⌘W and ⎋ do.
        if let close = window.standardWindowButton(.closeButton) {
            close.target = self
            close.action = #selector(closeButtonPressed(_:))
        }
        observeKey(of: window)
        observeClose(of: window)
    }

    private func observeClose(of window: NSWindow) {
        let center = NotificationCenter.default
        if let closeObserver { center.removeObserver(closeObserver) }
        closeObserver = nil
        guard let onWindowClosed else { return }
        // Capture this presentation's callback, so an old queued notification
        // cannot be retargeted to a newly opened flow.
        closeObserver = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { onWindowClosed() }
        }
    }

    @objc private func closeButtonPressed(_ sender: Any?) {
        onCloseButton?()
    }

    /// Reports whether the stage is key as the key window moves, once per
    /// window: every window's key changes are heard, since a sheet or a
    /// popover over the stage is a window of its own.
    private func observeKey(of window: NSWindow) {
        guard observedWindow !== window else { return }
        stopObservingKey()
        observedWindow = window
        let center = NotificationCenter.default
        keyObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                let became = note.object as? NSWindow
                MainActor.assumeIsolated { self?.keyMoved(to: became) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                let resigned = note.object as? NSWindow
                MainActor.assumeIsolated { self?.keyLeft(resigned) }
            },
        ]
        onKeyChange?(window.isKeyWindow || NSApp.keyWindow.map { Self.belongs($0, to: window) } ?? false)
    }

    /// A window became key: the stage is key when that window is the stage
    /// or shown over it.
    private func keyMoved(to became: NSWindow?) {
        guard let stage = observedWindow else { return }
        onKeyChange?(became.map { Self.belongs($0, to: stage) } ?? false)
    }

    /// A window stopped being key. When it was the stage's, the stage stays
    /// key only while the key window is still one of the stage's; the window
    /// that becomes key next reports itself.
    private func keyLeft(_ resigned: NSWindow?) {
        guard let stage = observedWindow, let resigned, Self.belongs(resigned, to: stage) else { return }
        let key = NSApp.keyWindow.flatMap { $0 === resigned ? nil : $0 }
        onKeyChange?(key.map { Self.belongs($0, to: stage) } ?? false)
    }

    /// Whether `window` is `stage`, or a sheet or child window shown over it,
    /// at any depth.
    static func belongs(_ window: NSWindow, to stage: NSWindow) -> Bool {
        var shown: NSWindow? = window
        while let current = shown {
            if current === stage { return true }
            shown = current.sheetParent ?? current.parent
        }
        return false
    }

    private func stopObservingKey() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        observedWindow = nil
    }

    // MARK: Frames a scratch run keeps to itself

    /// Turns AppKit's autosave off for `window`'s frame and its split views,
    /// now and as the window fills in. SwiftUI names a split view as it
    /// builds one, and AppKit writes a split view's dividers just after it
    /// resizes them, so each split view of the window is unnamed just before
    /// it resizes; the frame's name is cleared again as the window updates.
    private func keepFramesOutOfDefaults(_ window: NSWindow) {
        Self.stopAutosave(in: window)
        guard unsavedWindow !== window else { return }
        stopObservingAutosave()
        unsavedWindow = window
        let center = NotificationCenter.default
        autosaveObservers = [
            // Heard on the posting thread, so the name is gone before AppKit
            // saves; AppKit posts both on the main thread.
            center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: nil) { note in
                let updated = note.object as? NSWindow
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    if let updated, !updated.frameAutosaveName.isEmpty { updated.setFrameAutosaveName("") }
                }
            },
            center.addObserver(forName: NSSplitView.willResizeSubviewsNotification, object: nil, queue: nil) {
                [weak window] note in
                let split = note.object as? NSSplitView
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    guard let split, let window, split.window === window, split.autosaveName != nil else { return }
                    split.autosaveName = nil
                }
            },
        ]
    }

    /// Clears the frame's autosave name on `window` and on every split view
    /// already in it.
    private static func stopAutosave(in window: NSWindow) {
        if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
        for split in splitViews(in: window.contentView) where split.autosaveName != nil {
            split.autosaveName = nil
        }
    }

    private static func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        let own: [NSSplitView] = (view as? NSSplitView).map { [$0] } ?? []
        return own + view.subviews.flatMap { splitViews(in: $0) }
    }

    private func stopObservingAutosave() {
        for observer in autosaveObservers { NotificationCenter.default.removeObserver(observer) }
        autosaveObservers = []
        unsavedWindow = nil
    }
}

extension View {
    /// A white (or dark) card with a hairline. Rows inside use separators,
    /// never cards inside cards.
    func standardPanel(cornerRadius: CGFloat = AgentTheme.panelCornerRadius) -> some View {
        modifier(ControlSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Collection rails inside a split view share the paper; a hairline is the
    /// only separation.
    func paneMaterial() -> some View {
        modifier(PaneMaterialModifier())
    }

    /// A visible answer to the pointer: anything clickable brightens under it.
    func hoverHighlight(cornerRadius: CGFloat = AgentTheme.panelCornerRadius) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius))
    }

    /// The surface a screen's main collection sits on. Rows and tables scroll
    /// inside one standing card instead of floating on the canvas, where a
    /// bright desktop makes them hard to read.
    func collectionSurface() -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: AgentTheme.panelCornerRadius, style: .continuous))
            .standardPanel()
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.top, WorkspaceLayout.contentTopInset)
            .padding(.bottom, WorkspaceLayout.pageInset)
    }

    /// Accent selection for collection rows, separate from the system sidebar.
    func rowSelection(_ selected: Bool, cornerRadius: CGFloat = Radius.md) -> some View {
        modifier(RowSelectionModifier(selected: selected, cornerRadius: cornerRadius))
    }

    /// The keyboard's place in a setup-stage list or choice: an accent wash
    /// with a ring around it, the ring at full strength under Increase
    /// Contrast. One per list, where the keyboard is; the solid accent stays
    /// on the primary. Pair it with `.focusEffectDisabled()` so the system's
    /// own focus ring does not draw a second one.
    func softHighlight(_ isOn: Bool, inset: EdgeInsets = EdgeInsets()) -> some View {
        modifier(SoftHighlightModifier(isOn: isOn, shape: RoundedRectangle.control, inset: inset))
    }

    /// The same, in a shape of the caller's: a card's for a choice card, a
    /// cell's for a matrix cell.
    func softHighlight<S: InsettableShape>(_ isOn: Bool, in shape: S, inset: EdgeInsets = EdgeInsets()) -> some View {
        modifier(SoftHighlightModifier(isOn: isOn, shape: shape, inset: inset))
    }

    /// A card on the setup stage: opaque `controlBackground`, never material,
    /// because a material over the stage's near-black ground does not resolve
    /// to the card the mockups draw. Light adds a hairline and a point of
    /// shadow; dark keeps the quieter card edge.
    func stageCard(cornerRadius: CGFloat = Radius.lg) -> some View {
        modifier(StageCardModifier(cornerRadius: cornerRadius))
    }
}

private struct SoftHighlightModifier<S: InsettableShape>: ViewModifier {
    let isOn: Bool
    let shape: S
    let inset: EdgeInsets
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if isOn { shape.fill(AgentTheme.selection.opacity(Opacity.selectedWash)).padding(inset) }
            }
            .overlay {
                if isOn {
                    shape
                        .strokeBorder(
                            AgentTheme.selection.opacity(contrast == .increased ? 1 : Opacity.selectedStroke),
                            lineWidth: Hairline.ring
                        )
                        .padding(inset)
                }
            }
    }
}

private struct StageCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The card's own shape casts the shadow, never its words.
        content
            .background { shape.fill(AgentTheme.controlBackground).elevation(.cardRest) }
            .overlay {
                shape.strokeBorder(
                    HairlineStyle(base: colorScheme == .dark ? AgentTheme.hairlineStroke : AgentTheme.hairline),
                    lineWidth: Hairline.width)
            }
    }
}

extension AgentTheme {
    /// Lifts a card off the canvas. Light mode needs real white — thick
    /// material alone reads as gray against the bright glass — while dark mode
    /// already reads well and gets only a whisper.
    static let panelBrightening = dynamicPanelTint

    private static var dynamicPanelTint: Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: 0xFFFFFF, alpha: isDark ? 0.05 : 0.55)
            })
    }
}

extension EnvironmentValues {
    /// True while something floats over the window (the command palette).
    /// macOS hover tracking ignores what is drawn on top, so every hover
    /// highlight the app draws itself checks this before lighting up.
    @Entry var hoverSuppressed = false
}

private struct HoverHighlightModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hoverSuppressed) private var suppressed

    func body(content: Content) -> some View {
        content
            .background(
                AgentTheme.fillHover.opacity(hovering && !suppressed ? 1 : 0),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : AgentMotion.quick, value: hovering)
    }
}

private struct ControlSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            // A brightness layer over the material: white enough to stand off
            // the canvas in light mode, and nearly nothing in dark.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AgentTheme.panelBrightening)
            }
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
            }
    }
}

private struct PaneMaterialModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.hairlineTrailing()
    }
}

private struct RowSelectionModifier: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(AgentTheme.selection)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xxs)
                }
            }
    }
}

/// Group titles sit above their card, in the pane, so a card is only ever a
/// list of rows.
struct ControlGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            configuration.label
                .font(AgentFont.heading)
                .foregroundStyle(.primary)
                .padding(.horizontal, Space.xxs)
            VStack(spacing: 0) {
                configuration.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }
}

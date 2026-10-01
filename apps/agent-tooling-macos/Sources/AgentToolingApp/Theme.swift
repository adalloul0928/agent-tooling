import AppKit
import SwiftUI

/// Page headings, filters, and content share one leading edge.
enum WorkspaceLayout {
    static let pageInset = Space.xxxl
    static let contentTopInset = Space.lg
    static let sectionSpacing = Space.xxxl
    /// The inset of a sheet's body and an inspector's detail pane.
    static let paneInset = Space.xxl
}

/// Content uses neutral surfaces. NavigationSplitView owns the window's native
/// Liquid Glass sidebar, geometry, and active/inactive material behavior.
enum AgentTheme {
    /// The one accent: selection fills, prominent buttons, links, progress.
    static let selection = dynamic(light: 0x0065D1, dark: 0x0A64CD)

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

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

/// A deliberately small motion vocabulary. Short, transform-only animations
/// keep navigation legible without making data-heavy screens feel delayed.
enum AgentMotion {
    static let selection = Animation.snappy(duration: 0.22, extraBounce: 0)
    static let content = Animation.smooth(duration: 0.16)
    static let quick = Animation.easeOut(duration: 0.12)
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

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowConfigurationView)?.configureWindow()
    }
}

private final class WindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("agent-tooling-main")
        // The scene supplies a clear backing. The native material, rather than
        // an opaque window fill, determines the sidebar's appearance.
        window.isOpaque = false
        // The titlebar is part of the same canvas, not a strip of its own: the
        // content's ground runs to the top edge and the toolbar sits on it.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
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

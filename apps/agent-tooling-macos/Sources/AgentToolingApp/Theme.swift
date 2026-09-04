import AppKit
import SwiftUI

/// Tahoe: the window is one sheet of glass. The sidebar shows the desktop
/// through it; the content pane is an opaque "paper" inset with a concentric
/// radius so rows stay crisp. Colour is reserved for identity (what a thing is)
/// and for status glyphs beside labels; never for atmosphere.
enum AgentTheme {
    static let blue = Color(nsColor: .systemBlue)

    static let paneCornerRadius: CGFloat = 14
    static let panelCornerRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 226
    static let collapsedSidebarWidth: CGFloat = 64
    static let paperOpacity = 0.90

    /// The paper pane and its cards use the design pass's cool-tinted surfaces
    /// rather than AppKit's neutral greys, so pane and card keep real contrast.
    static let contentBackground = dynamic(light: 0xF7F8FB, dark: 0x1A1C24)
    static let controlBackground = dynamic(light: 0xFFFFFF, dark: 0x24262F)
    static let separator = Color(nsColor: .separatorColor)

    // Identity tiles. These say what a thing is and are never used for status.
    static let skill = dynamic(light: 0xFF8A1F, dark: 0xFF9D45)
    static let plugin = dynamic(light: 0xB457F0, dark: 0xC77DFF)
    static let mcpServer = dynamic(light: 0x22A6C9, dark: 0x4CC4E3)
    static let profile = dynamic(light: 0x5E5CE6, dark: 0x7D7BFF)
    static let graphite = dynamic(light: 0x4A5068, dark: 0x7A8098)

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

/// The window itself is the one translucent surface. Everything operational
/// sits on the paper pane above it, so the desktop never competes with rows.
struct DesktopGlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
    }
}

extension View {
    /// A white (or dark) card with a hairline. Rows inside use separators,
    /// never cards inside cards.
    func standardPanel(cornerRadius: CGFloat = AgentTheme.panelCornerRadius) -> some View {
        modifier(ControlSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// The content pane: a 90% paper inset from the glass window edge.
    func paperPane() -> some View {
        modifier(PaperPaneModifier())
    }

    /// Collection rails inside a split view share the paper; a hairline is the
    /// only separation.
    func paneMaterial() -> some View {
        modifier(PaneMaterialModifier())
    }

    /// Accent selection for collection rows: the same capsule-cornered fill as
    /// the sidebar, so selection reads as one shape across the app.
    func rowSelection(_ selected: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(RowSelectionModifier(selected: selected, cornerRadius: cornerRadius))
    }
}

private struct ControlSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AgentTheme.controlBackground)
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AgentTheme.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

private struct PaperPaneModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: AgentTheme.paneCornerRadius, style: .continuous)
                    .fill(AgentTheme.contentBackground.opacity(reduceTransparency ? 1 : AgentTheme.paperOpacity))
            }
            .clipShape(RoundedRectangle(cornerRadius: AgentTheme.paneCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AgentTheme.paneCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.09 : 0.85), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 3, y: 1)
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8))
    }
}

private struct PaneMaterialModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                Rectangle().fill(AgentTheme.separator.opacity(0.45)).frame(width: 0.5)
            }
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
                        .fill(AgentTheme.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
    }
}

/// Group titles sit above their card, in the pane, so a card is only ever a
/// list of rows.
struct ControlGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                configuration.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }
}

import AppKit
import SwiftUI

/// Page headings, filters, and content share one leading edge.
enum WorkspaceLayout {
    static let pageInset: CGFloat = 24
    static let contentTopInset: CGFloat = 12
    static let sectionSpacing: CGFloat = 24
}

/// Content uses neutral surfaces. NavigationSplitView owns the window's native
/// Liquid Glass sidebar, geometry, and active/inactive material behavior.
enum AgentTheme {
    static let blue = Color(nsColor: .systemBlue)
    static let selection = dynamic(light: 0x0065D1, dark: 0x0A64CD)

    static let panelCornerRadius: CGFloat = 12

    /// Neutral content surfaces leave the desktop's color to the native glass.
    static let contentBackground = dynamic(light: 0xF5F5F7, dark: 0x1C1C1E)
    static let controlBackground = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let separator = Color(nsColor: .separatorColor)

    // Neutral symbols identify item types; color is reserved for actions and status.
    static let graphite = dynamic(light: 0x6E6E73, dark: 0xAEAEB2)
    static let skill = graphite
    static let plugin = graphite
    static let mcpServer = graphite
    static let profile = graphite

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
struct WindowBackdropMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
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

    /// Accent selection for collection rows, separate from the system sidebar.
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
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AgentTheme.separator.opacity(0.35), lineWidth: 0.5)
            }
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
                        .fill(AgentTheme.selection)
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

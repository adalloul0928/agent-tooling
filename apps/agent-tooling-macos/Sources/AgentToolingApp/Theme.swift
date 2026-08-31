import AppKit
import SwiftUI

enum AgentTheme {
    // Quartz: macOS system surfaces, SF typography, and one blue action color.
    // The window material is the only glass layer; content surfaces are quiet
    // and substantially opaque so the desktop never becomes interface noise.
    static let blue = Color(nsColor: .systemBlue)
    static let desktopGlassOpacity = 0.96

    static let panelCornerRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 232
    static let collapsedSidebarWidth: CGFloat = 64
    static let contentBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
}

/// The window itself is the one translucent surface. Content sits on ordinary
/// macOS surfaces above it, so the desktop is never competing with controls.
struct DesktopGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
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
    func standardPanel(cornerRadius: CGFloat = AgentTheme.panelCornerRadius) -> some View {
        modifier(ControlSurfaceModifier(cornerRadius: cornerRadius))
    }

    func paneMaterial() -> some View {
        modifier(PaneMaterialModifier())
    }
}

private struct ControlSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AgentTheme.controlBackground.opacity(reduceTransparency ? 1 : 0.90))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AgentTheme.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

private struct PaneMaterialModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AgentTheme.contentBackground)
    }
}

struct ControlGroupBoxStyle: GroupBoxStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 15)
                .frame(minHeight: 43, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.32)
                }
            configuration.content
        }
        .background {
            RoundedRectangle(cornerRadius: AgentTheme.panelCornerRadius, style: .continuous)
                .fill(AgentTheme.controlBackground.opacity(reduceTransparency ? 1 : 0.88))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AgentTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(AgentTheme.separator.opacity(0.55), lineWidth: 0.5)
        }
    }
}

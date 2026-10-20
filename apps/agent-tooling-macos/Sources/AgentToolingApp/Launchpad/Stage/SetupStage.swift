import AgentToolingCore
import SwiftUI

/// Fixed-size setup canvas with independent scrolling regions and a review overlay.
/// Respects Reduce Transparency and exposes only managed clients to descendant
/// marks. The drag band and footer remain outside scrolling content.
struct SetupStage<Content: View, Footer: View, Overlay: View>: View {
    var managedClients: [ClientKind]
    let content: Content
    let footer: Footer
    let overlay: Overlay
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        managedClients: [ClientKind] = ClientKind.allCases, @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer, @ViewBuilder overlay: () -> Overlay
    ) {
        self.managedClients = managedClients
        self.content = content()
        self.footer = footer()
        self.overlay = overlay()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.top, StageLayout.Grid.contentTop)
                .padding(.horizontal, StageLayout.Grid.sideInset)
                .padding(.bottom, StageLayout.Grid.bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
                .frame(height: StageLayout.Grid.footerHeight)
        }
        .overlay { overlay }
        .frame(width: WindowSize.stage.width, height: WindowSize.stage.height)
        .background { StageGround(opaque: reduceTransparency) }
        .overlay { StageRim() }
        .environment(\.availableClients, managedClients)
        .ignoresSafeArea()
    }
}

/// The stage's ground, laid over the window's own material, or opaque.
struct StageGround: View {
    let opaque: Bool

    var body: some View {
        ZStack {
            if opaque {
                AgentTheme.stageGroundOpaque
            } else {
                WindowBackdropMaterial()
                AgentTheme.stageGround
            }
            AgentTheme.stageGroundShade
        }
        .accessibilityHidden(true)
    }
}

/// The stage's rim: a lit top edge inside the window's own border, and the
/// line around it, following the window's corners.
struct StageRim: View {
    var body: some View {
        ConcentricRectangle()
            .stroke(AgentTheme.stageRimEdge, lineWidth: Hairline.width)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AgentTheme.stageRimTop)
                    .frame(height: Hairline.width)
                    .padding(.horizontal, Radius.xl)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

import SwiftUI

struct ToolIdentityIcon: View {
    let packageID: String
    var fallback: ToolingKind = .plugin
    var size: CGFloat = Size.identityIconLarge

    var body: some View {
        Image(systemName: fallback.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * Proportion.tileSymbol, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: size * Proportion.iconCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * Proportion.iconCorner, style: .continuous)
                    .strokeBorder(AgentTheme.shadow, lineWidth: Hairline.width)
            }
            .accessibilityHidden(true)
    }
}

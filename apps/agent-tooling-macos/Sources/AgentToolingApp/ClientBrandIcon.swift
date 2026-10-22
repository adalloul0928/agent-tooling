import AgentToolingCore
import SwiftUI

struct ClientBrandIcon: View {
    let client: ClientKind
    let size: CGFloat

    var body: some View {
        Image(systemName: Self.symbol(for: client))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func symbol(for client: ClientKind) -> String {
        switch client {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "text.bubble"
        case .gemini: "sparkles"
        case .kiro: "terminal"
        }
    }
}

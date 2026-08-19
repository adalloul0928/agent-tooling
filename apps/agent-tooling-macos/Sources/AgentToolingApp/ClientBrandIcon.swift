import AgentToolingCore
import SwiftUI

struct ClientBrandIcon: View {
    let client: ClientKind
    var size: CGFloat = 22

    var body: some View {
        Image(assetName, bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch client {
        case .codex: "ClientCodex"
        case .claude: "ClientClaude"
        case .gemini: "ClientGemini"
        }
    }
}

import AgentToolingCore
import SwiftUI

struct ClientSelectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clients you use").font(.headline)
            Text(
                "Unchecked clients are hidden throughout Agent Tooling and excluded from checks and changes. Their software and configuration stay on this Mac."
            )
            .font(.caption).foregroundStyle(.secondary)
            ForEach(ClientKind.allCases) { client in
                Toggle(
                    isOn: Binding(
                        get: { model.isClientEnabled(client) },
                        set: { _ = model.setClientEnabled(client, enabled: $0) }
                    )
                ) {
                    HStack(spacing: 10) {
                        ClientBrandIcon(client: client, size: 20)
                        Text(client.rawValue)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Use \(client.rawValue)")
                .disabled(model.isInteractionLocked)
            }
            if model.enabledClients.isEmpty {
                Text("Select a client whenever you’re ready. Your local library remains available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

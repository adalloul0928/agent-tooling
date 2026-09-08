import AgentToolingCore
import Foundation

/// One verdict per client from the last local check, shared by the sidebar
/// and the Overview conduit so both say the same thing.
struct ClientVerdict {
    let state: HealthState
    let text: String
}

extension AppModel {
    func clientVerdict(for client: ClientKind) -> ClientVerdict {
        let observations = visibleTargetObservations.filter { $0.surface.client == client }
        guard !observations.isEmpty else { return ClientVerdict(state: .pending, text: "Not checked yet") }
        if observations.contains(where: \.isCommandAvailable) {
            let checked = observations.map(\.lastScannedAt).max().map { date in
                Calendar.current.isDateInToday(date)
                    ? "Checked \(date.formatted(date: .omitted, time: .shortened))"
                    : "Checked \(date.formatted(.dateTime.month(.abbreviated).day()))"
            }
            return ClientVerdict(state: .healthy, text: checked ?? "Available")
        }
        return ClientVerdict(
            state: .attention,
            text: observations.contains(where: \.installed) ? "Command unavailable" : "Not found"
        )
    }
}

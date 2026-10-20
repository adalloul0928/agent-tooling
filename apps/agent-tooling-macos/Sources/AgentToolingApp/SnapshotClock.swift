import SwiftUI

/// Supplies the once-a-minute clock used by relative timestamps. A nil value
/// falls back to wall time without scheduling updates, as in previews and tests.
extension EnvironmentValues {
    @Entry var snapshotNow: Date? = nil
}

extension View {
    /// Updates relative times without changing task identity or starting session work.
    /// An injected `snapshotNow` takes precedence, keeping render fixtures deterministic.
    func minuteTicker() -> some View {
        modifier(MinuteTicker())
    }
}

/// The ticker's clock: once a minute, unless a `snapshotNow` was set above.
private struct MinuteTicker: ViewModifier {
    @Environment(\.snapshotNow) private var injected

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content.environment(\.snapshotNow, injected ?? context.date)
        }
    }
}

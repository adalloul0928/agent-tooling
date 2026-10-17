import SwiftUI

/// The "now" the relative time strings on screen should measure against.
///
/// A `SnapshotTime` string is computed once per render, so without something
/// changing the inputs a "just now" stays "just now" for as long as the view is
/// on screen. The window sets this from a once-a-minute timeline, and the views
/// that show relative times read it and pass it to `SnapshotTime` as `now:`.
/// When nothing sets it — a preview, a render test, a screen the ticker does
/// not wrap — it is `nil` and the caller falls back to the wall clock, so the
/// strings still read correctly; they simply do not re-tick on their own.
extension EnvironmentValues {
    @Entry var snapshotNow: Date? = nil
}

extension View {
    /// Re-evaluates the relative time strings inside this view about once a
    /// minute, without re-running any `.task` the view carries.
    ///
    /// The ticker is a `TimelineView` around the content, and the only thing it
    /// changes is the `snapshotNow` environment value. It starts no work and
    /// touches no session: a re-render is not a re-scan, and the `.task`
    /// identities the content declares are untouched, so the once-a-minute
    /// redraw cannot restart a check.
    func minuteTicker() -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            self.environment(\.snapshotNow, context.date)
        }
    }
}

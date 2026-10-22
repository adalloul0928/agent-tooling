/// Every word the setup stage shows, in one namespace per area of the stage,
/// so a wording test can pin each string and a style test can hold all of
/// them to the house rules: apps, never clients; the one-character ellipsis
/// only on a control that opens something; curly quotes and apostrophes; the
/// app order; no exclamation marks.
///
/// Each area lives in its own `LaunchpadCopy+<Area>.swift`, owned by the
/// package that draws the area. A sentence that says something failed goes in
/// that area's nested `Failures` enum, and ends "Nothing was changed."
enum LaunchpadCopy {
    /// Welcome (S01).
    enum Welcome {}
    /// The screen shown instead of the stage's first one when this Mac's
    /// library record cannot be read.
    enum Unreadable {}
    /// The footer bar, its confirm, and the stage's spoken summaries.
    enum Footer {}
    /// Your apps (S02, V01).
    enum Apps {}
    /// What Agent Tooling reads, and the read (S04, S05).
    enum Reads {}
    /// Your library, as read (S06).
    enum Found {}
    /// Make skills yours and add from the catalogs (S08).
    enum Library {}
    /// Put tools in apps (S10).
    enum Place {}
    /// Agent Tooling's own connection and Before you start (S00, S11).
    enum Helper {}
    /// The review panel (S12).
    enum Review {}
    /// Let your assistant help, and How Agent Tooling behaves (S15, S16).
    enum Preferences {}
    /// Your other Macs (S17).
    enum Macs {}
    /// Join and You joined (J01, V08, J02).
    enum Join {}
    /// Done (S22).
    enum Done {}
    /// Home's Finish setting up card (P01).
    enum FinishSetup {}
    /// What the stage kit's own pieces say: the mark, the poster's places
    /// and the manifest's lists.
    enum Kit {}

    /// Names in a sentence, as the stage writes a list: "Codex", "Codex and
    /// Claude Code", "Codex, Claude Code and Gemini CLI". The caller passes
    /// apps in the app order; the list keeps the order it is given.
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

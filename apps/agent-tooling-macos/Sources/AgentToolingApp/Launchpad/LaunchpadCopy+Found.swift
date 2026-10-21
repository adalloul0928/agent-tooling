import AgentToolingCore

/// Your library, as read (S06), with its rerun variant: the header, the lines
/// under each read tile, the list of what the library holds and each row's
/// popover. The sign-in lines are `LaunchpadCopy.Found.SignIn`.
extension LaunchpadCopy.Found {
    static let eyebrow = "Your library"
    static let title = "Here is what this Mac has"
    /// Follows the holdings sentence on a first run. A rerun's library may
    /// already have things installed and assigned, so it is left out there.
    static let nothingAssignedYet = "Nothing is installed or assigned yet."

    // The lines under a tile.

    /// A found app that was turned off, so it was not read.
    static let offNotRead = "Off · not read"

    // The list.

    static let listHeading = "In your library"
    /// The list's count after its heading: "· 8".
    static func listCount(_ count: Int) -> String {
        "· \(count)"
    }

    /// The list's heading as VoiceOver reads it: the count after a comma,
    /// with its noun and without the drawn separator ("In your library, 8
    /// entries"). Each row is one entry of the library, as Done counts them.
    static func listHeadingSpoken(_ count: Int) -> String {
        "\(listHeading), \(CountNoun.entry.phrase(count))"
    }

    /// The stage audit's count, at the list's right: "8 things to look at,
    /// later on Checkup".
    static func thingsToLookAt(_ count: Int) -> String {
        count == 0 ? "Nothing to look at on Checkup" : "\(CountNoun.thing.phrase(count)) to look at, later on Checkup"
    }

    /// An empty library, in place of the list.
    static let empty = "Nothing was found in these apps yet."

    /// A row's detail beside its name.
    static func onlyIn(_ app: String) -> String {
        "Only in \(app)"
    }

    static func configuredIn(_ apps: Int) -> String {
        "Configured in \(CountNoun.app.phrase(apps))"
    }

    // A row's popover.

    /// One copy of a skill: the apps that read it there.
    static func readBy(_ apps: String) -> String {
        "Read by \(apps)"
    }

    static func files(_ count: Int) -> String {
        CountNoun.file.phrase(count)
    }

    /// A copy whose folder could not be measured.
    static let filesUnknown = "Files not counted"
    /// Where the row is, for anything that is not a skill.
    static func heldBy(_ apps: String) -> String {
        "In \(apps)"
    }

    static let heldByNone = "In none of the apps this Mac manages"
    static let checkAgain = "Check again"
    static let checkingAgain = "Checking again…"

    /// What the read saw and did not record, when it saw any: a link that
    /// opens the list, and the list's title.
    static let notRecordedLink = "Not recorded, and why…"
    static let notRecordedTitle = "Not recorded, and why"

    // What VoiceOver says.

    /// A row: "Frontend Design, skill, 2 copies · 2 versions, Unmanaged, in
    /// Codex, Claude Code and Gemini CLI".
    static func rowLabel(_ name: String, kind: String, detail: String?, ownership: String, apps: String?) -> String {
        let place = apps.map { "in \($0)" } ?? "in none of this Mac’s apps"
        return ([name, kind] + [detail].compactMap { $0 } + [ownership, place]).joined(separator: ", ")
    }

    /// What a row is, in the Library's nouns.
    static func kindName(_ kind: ArtifactKind) -> String {
        switch kind {
        case .skill: CountNoun.skill.singular
        case .nativePlugin, .package: CountNoun.plugin.singular
        case .mcpServer: CountNoun.connection.singular
        case .preset: "preset"
        case .logicalProject: "project"
        }
    }

    /// A row's hint: Space opens what it holds.
    static let rowHint = "Space shows its copies and where they are."
}

extension CountNoun {
    fileprivate static let app = CountNoun("app")
    fileprivate static let thing = CountNoun("thing")
    fileprivate static let entry = CountNoun("entry", plural: "entries")
    fileprivate static let file = CountNoun("file")
}

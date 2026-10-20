import AgentToolingCore
import Foundation

extension LaunchpadCopy.Library {
    // The header.

    static let eyebrow = "Your library"
    static let title = "Start your library"
    static let subtitle =
        "Make the skills you already have yours, and add a few tools if you like. The apps’ folders are not changed; installing comes later, in one review."

    // Make your skills yours.

    static let makeYoursHeading = "Make your skills yours"

    /// ⌘A's button, which ticks every skill and adds them with whatever else
    /// is ticked or picked: "Add all 3 to library".
    static func addAll(_ count: Int) -> String {
        count == 1 ? "Add to library" : "Add all \(count) to library"
    }

    /// One copy, in one app: "Only in Claude Code".
    static func onlyIn(_ app: String) -> String {
        "Only in \(app)"
    }

    /// The apps' copies differ: "Codex and Claude Code have different copies.
    /// Choose which copy to bring in:".
    static func differentCopies(_ apps: String) -> String {
        "\(apps) have different copies. Choose which copy to bring in:"
    }

    /// Every copy holds the same skill: "Same in Codex and Claude Code".
    static func sameIn(_ apps: String) -> String {
        "Same in \(apps)"
    }

    /// A copy, named for the app it is in: "Codex’s copy".
    static func copy(in app: String) -> String {
        "\(app)’s copy"
    }

    /// "3 files · changed Oct 2".
    static func copyDetail(files: Int, changed: String?) -> String {
        let count = CountNoun.file.phrase(files)
        return changed.map { "\(count) · changed \($0)" } ?? count
    }

    /// Under the chooser, about the copy that is not chosen: "Codex’s copy is
    /// older (2 files, Aug 14). It stays in Codex either way."
    static func otherCopyIsOlder(in app: String, files: Int, changed: String) -> String {
        "\(app)’s copy is older (\(CountNoun.file.phrase(files)), \(changed)). It stays in \(app) either way."
    }

    static func otherCopyIsNewer(in app: String, files: Int, changed: String) -> String {
        "\(app)’s copy is newer (\(CountNoun.file.phrase(files)), \(changed)). It stays in \(app) either way."
    }

    /// When the copies' dates say nothing about which is newer.
    static func otherCopyStays(in app: String) -> String {
        "\(app)’s copy stays in \(app) either way."
    }

    static let otherCopiesStay = "The other copies stay where they are either way."

    /// The chooser, as VoiceOver names its radio group.
    static func chooserLabel(_ name: String) -> String {
        "Copy of \(name) to bring in"
    }

    /// A copy in the chooser, as VoiceOver reads it: "Claude Code’s copy, 3
    /// files, changed Oct 2".
    static func copyLabel(in app: String, files: Int?, changed: String?) -> String {
        [copy(in: app), files.map { CountNoun.file.phrase($0) }, changed.map { "changed \($0)" }]
            .compactMap(\.self).joined(separator: ", ")
    }

    /// A row's apps, as VoiceOver reads its marks: "In Codex, Claude Code and
    /// Gemini CLI".
    static func inApps(_ apps: String) -> String {
        "In \(apps)"
    }

    static let adding = "Adding…"
    static let personalLibrary = "Personal library"

    /// Identifies skills maintained by another tool.
    static func keptInStep(by manager: String) -> String {
        "Kept in step by \(manager) — left alone"
    }

    /// Section A when the apps hold no loose skill to make yours.
    static let nothingToMakeYours = "Your apps hold no skills of their own to bring in."
    /// Section A when every loose skill is in the library already.
    static let everythingIsYours = "Every skill your apps hold is in your library already."

    // Why a skill was not made yours. On S08 each is the row's own sentence,
    // shown where its clause was, or under the chooser for the copy chosen,
    // so it is about "it". Where nothing beside it says which skill, as in
    // Checkup's message, the skill's name leads it instead (`naming`).

    /// "Its SKILL.md calls it frontend-ui, not frontend-design, so it cannot
    /// be added yet. Rename one to match."
    static func calledOtherwise(recorded: String, found: String, naming name: String? = nil) -> String {
        "\(possessive(name)) SKILL.md calls it \(found), not \(recorded), so it cannot be added yet. Rename one to match."
    }

    /// "It is in your library already."
    static func alreadyYours(naming name: String? = nil) -> String {
        "\(name ?? it) is in your library already."
    }

    /// "It comes with a plugin, so it stays with its plugin."
    static func staysWithItsPlugin(naming name: String? = nil) -> String {
        "\(name ?? it) comes with a plugin, so it stays with its plugin."
    }

    /// "It is no longer in your library. Check your apps again."
    static func notInLibrary(naming name: String? = nil) -> String {
        "\(name ?? it) is no longer in your library. Check your apps again."
    }

    /// "This copy could not be read, so it cannot be added yet."
    static func notReadable(naming name: String? = nil) -> String {
        "\(copyOf(name)) could not be read, so it cannot be added yet."
    }

    /// "This copy follows a repository, so it is added from Discover
    /// instead."
    static func followsARepository(naming name: String? = nil) -> String {
        "\(copyOf(name)) follows a repository, so it is added from Discover instead."
    }

    /// A row the library refused only as the one revision was written, with
    /// no reason a fresh look gives: "It could not be added to your library."
    static func notAdded(naming name: String? = nil) -> String {
        "\(name ?? it) could not be added to your library."
    }

    // Why a copy could not be read into the library before it was offered.

    static let noSkillMD = "This folder has no SKILL.md, so it is not a skill to add."
    static let unreadableSkillMD = "Its SKILL.md does not say what the skill is called and what it does, so it cannot be added yet."
    static let insidePluginFolder = "This folder is a plugin, so it stays with its plugin."

    /// The sentence for one refused row: about "it" beside the row's name,
    /// about `name` where nothing else says which skill.
    static func sentence(for refusal: LibraryAdditionRefusal, naming name: String? = nil) -> String {
        switch refusal {
        case .declaredNameMismatch(_, let recorded, let found): calledOtherwise(recorded: recorded, found: found, naming: name)
        case .notAdoptable(_, .missing): notInLibrary(naming: name)
        case .notAdoptable(_, .alreadyYours): alreadyYours(naming: name)
        case .notAdoptable(_, .notALooseSkill): staysWithItsPlugin(naming: name)
        case .notAdoptable(_, .notRead): notReadable(naming: name)
        case .notAdoptable(_, .followsAnUpstream): followsARepository(naming: name)
        case .catalog(_, let error): sentence(forListing: error, naming: name)
        case .intake(_, .upstreamAlreadyManaged), .intake(_, .identityCollision), .intake(_, .sourceIdentityConflict):
            alreadyYours(naming: name)
        case .intake: notAdded(naming: name)
        }
    }

    /// Why a catalog listing was not added, naming its card: its own words,
    /// unless it is in the library already.
    static func sentence(forListing error: NativePackageAdoptionError, naming name: String?) -> String {
        switch error {
        case .alreadyInLibrary, .identityCollision: alreadyYours(naming: name)
        default: notAdded(naming: name, because: error.localizedDescription)
        }
    }

    /// Why a copy could not be read into the library before it was offered.
    static func sentence(forUnreadable error: any Error) -> String {
        switch error {
        case WorkspaceSkillPreparationError.missingSkillDefinition: noSkillMD
        case WorkspaceSkillPreparationError.invalidSkillDefinition: unreadableSkillMD
        case WorkspaceSkillPreparationError.pluginPackageRoot: insidePluginFolder
        default: notReadable()
        }
    }

    private static let it = "It"

    /// "Its", or "Frontend Design’s".
    private static func possessive(_ name: String?) -> String {
        name.map { "\($0)’s" } ?? "Its"
    }

    /// "This copy", or "Frontend Design’s copy".
    private static func copyOf(_ name: String?) -> String {
        name.map { "\($0)’s copy" } ?? "This copy"
    }

    // From your apps' catalogs.

    static let catalogsHeading = "From your apps’ catalogs"
    static let writeYourOwn = "Write your own…"
    static let pasteCommand = "Paste a command or URL…"

    /// A card's source with the count a catalog reported: "skills.sh ·
    /// anthropics/skills · 12.4k installs".
    static func source(_ source: String, installs: Int) -> String {
        "\(source) · \(CompactCountFormatter.string(for: installs).lowercased()) \(CountNoun.install.word(for: installs))"
    }

    static let inLibrary = "In library"
    static let needsGit = "Needs Git"
    /// A card the library did not take, on its last line, beside a warning
    /// glyph. Why is said under the cards.
    static let notAddedMark = "Not added"

    /// Under the catalog label when the shelf shows a page kept from an
    /// earlier read: "Showing what was read Oct 16. skills.sh could not be
    /// reached."
    static func offline(readOn date: String) -> String {
        "Showing what was read \(date). skills.sh could not be reached."
    }

    static let skillsShUnreachable = "skills.sh could not be reached."

    /// A card, as VoiceOver reads its checkbox: "Supabase, Supabase database,
    /// auth and storage from Claude Code. Claude Code’s catalog".
    static func cardLabel(name: String, summary: String, source: String) -> String {
        "\(name), \(summary) \(source)"
    }

    // Why a card was not added, under the cards. Each names its card, since
    // nothing beside it does, and says only what happened to that card: the
    // others in the same Add may well have landed.

    /// "MCP Builder could not be fetched from its repository, so it was not
    /// added."
    static func notFetched(_ name: String) -> String {
        "\(name) could not be fetched from its repository, so it was not added."
    }

    /// A skills.sh listing that names no repository to fetch the skill from.
    static func namesNoRepository(_ name: String) -> String {
        "\(name)’s listing names no repository to fetch it from, so it was not added."
    }

    /// A catalog listing the library refused, in the refusal's own words:
    /// "Vercel was not added. You removed this package from your library
    /// before. …".
    static func notAdded(naming name: String?, because reason: String) -> String {
        name.map { "\($0) was not added. \(reason)" } ?? reason
    }

    /// The fine print, with a skill inside a plugin as its example when the
    /// library has one: "Skills inside plugins, like Triage Issue in Sentry,
    /// stay with their plugin. Skills you leave stay where they are, and
    /// Checkup keeps listing them."
    static func finePrint(example: (skill: String, plugin: String)?) -> String {
        let plugins =
            example.map { "Skills inside plugins, like \($0.skill) in \($0.plugin), stay with their plugin." }
            ?? "Skills inside plugins stay with their plugin."
        return plugins + " Skills you leave stay where they are, and Checkup keeps listing them."
    }

    // Write your own…, as it opens over the stage, where putting a skill in
    // apps is the next step rather than the editor's own.

    /// Under the editor's first page, in place of where Install is, naming
    /// the stage's next step as its footer does.
    static let editorPlacement =
        "Saving adds the skill to your library. Which apps use it is chosen in the next step, \(LaunchpadCopy.Footer.stepPutInApps)."
    /// The editor's last page, on its Next row.
    static let editorNext = "\(LaunchpadCopy.Footer.stepPutInApps), the next step"

    // The footer.

    /// The primary, counting the skills ticked and the tools picked: "Add 3
    /// to library".
    static func add(_ count: Int) -> String {
        "Add \(count) to library"
    }

    /// When an Add, or a sheet's save, wrote nothing at all.
    enum Failures {
        /// The one revision could not be written, so none of what was asked
        /// for landed: "Release Notes and Supabase could not be added to your
        /// library. Nothing was changed."
        static func notAdded(_ names: [String]) -> String {
            "\(LaunchpadCopy.list(names)) could not be added to your library. Nothing was changed."
        }

        // Why the skill written in the editor was not saved.

        static let nameTaken = "Your library already has a skill with that name. Choose another name. Nothing was changed."
        static let contentUnreachable =
            "This library cannot reach its stored content, so the skill was not saved. Nothing was changed."
        static let libraryMoved = "Your library changed while this was open. Create the skill again. Nothing was changed."
        static let notAnIdentifier = "Use lowercase letters, numbers and single hyphens for the name. Nothing was changed."
        static let incompleteDefinition =
            "The definition does not say what the skill is called and what it does. Nothing was changed."
        /// Any other reason.
        static let notSaved = "That skill could not be saved to your library. Nothing was changed."
    }
}

extension CountNoun {
    fileprivate static let file = CountNoun("file")
    fileprivate static let install = CountNoun("install")
}

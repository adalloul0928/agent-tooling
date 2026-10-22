import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Before you start's and Let your apps ask's words, pinned to the fragments
/// (`01-s00-move.html`, `08-s11-ask.html`) and to plan §6's NEW sentences;
/// the words derived from something else checked against it: the helper's
/// tools against what the explainer lists, each app's command against the
/// shape its own tool takes, the counts against the lists they count.
@Suite("Launchpad helper wording", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadHelperWordingTests {
    typealias Copy = LaunchpadCopy.Helper

    // MARK: - Before you start (S00)

    @Test func beforeYouStartSaysWhatTheFragmentSays() {
        #expect(Copy.moveTitle == "Put Agent Tooling in Applications")
        #expect(Copy.moveSubtitle == "Your apps and Raycast find Agent Tooling by where it lives.")
        #expect(Copy.runningFrom == "Running from")
        #expect(Copy.movesTo == "Moves to")
        #expect(Copy.diskImage(named: "Agent Tooling") == "The disk image “Agent Tooling”")
        #expect(Copy.temporaryPlace == "A temporary place macOS chose")
        #expect(Copy.olderCopyThere == "An older Agent Tooling is there. It goes to the Trash.")
        #expect(Copy.movesFromDiskImage == "Agent Tooling copies itself to Applications, opens from there and ejects the disk image.")
        #expect(Copy.imageStays("Agent-Tooling-0.1.0-arm64.dmg", in: "Downloads") == "Agent-Tooling-0.1.0-arm64.dmg stays in Downloads.")
        #expect(Copy.moveAndReopen == "Move to Applications and reopen")
        #expect(Copy.replaceAndReopenEllipsis == "Replace and reopen…")
        #expect(Copy.replaceAndReopen == "Replace and reopen")
        #expect(Copy.moving == "Moving…")
        #expect(Copy.keepItHere == "Keep it here")
        #expect(Copy.keepItHereHelp == "Connecting your apps to Agent Tooling waits until it is in Applications.")
        #expect(Copy.replaceQuestion == "Replace the Agent Tooling in Applications?")
        #expect(Copy.replaceDetail == "The older copy goes to the Trash. Nothing else on this Mac changes.")
        #expect(Copy.cancel == "Cancel")
        #expect(Copy.showInFinder == "Show in Finder")
        #expect(Copy.Failures.notMoved == "Agent Tooling could not be copied to Applications. Nothing was changed.")
    }

    /// Plan §6's sentences for Before you start, flagged to the owner (O6).
    @Test func beforeYouStartsNewSentences() {
        #expect(Copy.downloadsFolder == "Your Downloads folder")
        #expect(Copy.folderOutsideApplications == "A folder outside Applications")
        #expect(
            Copy.stillTranslocated
                == "macOS is still running Agent Tooling from a temporary place. Quit, then open it from Applications.")
        #expect(Copy.quit == "Quit Agent Tooling")
        #expect(
            Copy.movesFromFolder
                == "Agent Tooling copies itself to Applications and opens from there. The copy you opened stays where it is.")
        #expect(Copy.copyAlreadyThere(version: "0.1.0") == "Agent Tooling 0.1.0 is already there.")
        #expect(Copy.copyAlreadyThere(version: nil) == "Agent Tooling is already there.")
        #expect(Copy.openFromApplicationsTitle == "Open it from Applications")
        #expect(
            Copy.openFromApplications
                == "Agent Tooling is in Applications now, but it could not be opened from there. Open it from Applications.")
        #expect(
            Copy.Failures.otherCopyOpen == "The Agent Tooling in Applications is open. Quit it, then try again. Nothing was changed.")
    }

    /// The disk image's caption as the fragment reads it, its file name held
    /// whole with hyphens that never end a line; a translocated copy's path as
    /// the fragment elides it.
    @Test func theCaptionAndThePathsReadAsTheFragmentSetsThem() async throws {
        let stage = try await GalleryMoveStage(.diskImage)
        defer { stage.remove() }
        let model = LaunchpadMoveModel.of(stage.flow)
        model.use(stage.services)

        #expect(
            model.caption.replacingOccurrences(of: "\u{2011}", with: "-")
                == "Agent Tooling copies itself to Applications, opens from there and ejects the disk image. Agent-Tooling-0.1.0-arm64.dmg stays in Downloads."
        )
        #expect(!model.caption.contains("-"), "no hyphen a line could break at")
        #expect(model.runningFrom.words == "The disk image “Agent Tooling”")
        #expect(model.runningFrom.paths == ["/Volumes/Agent Tooling/Agent Tooling.app"])
        #expect(model.destinationPath == "/Applications/Agent Tooling.app")
        #expect(
            LaunchpadMoveModel.translocatedPaths(
                URL(filePath: "/private/var/folders/x8/k1v9/T/AppTranslocation/4F1E/d/Agent Tooling.app", directoryHint: .isDirectory))
                == ["/private/var/folders/…/AppTranslocation/…/Agent Tooling.app", "…/AppTranslocation/…/Agent Tooling.app"])
    }

    // MARK: - Let your apps ask (S11)

    @Test func letYourAppsAskSaysWhatTheFragmentSays() {
        #expect(Copy.askEyebrow == "Put in apps")
        #expect(Copy.askTitle == "Let your apps ask Agent Tooling")
        #expect(
            Copy.askSubtitle
                == "Your apps can look things up in your library and ask you for changes. They can only ask; every change still waits for you here."
        )
        #expect(Copy.canLookUp(9) == "Can look up · 9")
        #expect(Copy.canOnlyAsk(5) == "Can only ask · 5")
        #expect(Copy.queuedRequest == "A queued request changes nothing. It waits on Home until you approve or decline it.")
        #expect(Copy.addTo == "Add Agent Tooling to")
        #expect(Copy.notFound == "Not found on this Mac")
        #expect(Copy.alreadyConnected == "Already connected")
        #expect(Copy.waitsForVersion == "Waits for a version")
        #expect(Copy.moveFirst == "Move Agent Tooling to Applications first, so your apps can find it.")
        #expect(Copy.moveToApplications == "Move to Applications…")
        #expect(Copy.noHelper == "This build of Agent Tooling has no helper.")
        #expect(Copy.review(changes: 4) == "Review 4 changes…")
        #expect(Copy.review(changes: 5) == "Review 5 changes…")
        #expect(Copy.review(changes: 2) == "Review 2 changes…")
        #expect(Copy.review(changes: 1) == "Review 1 change…")
        #expect(Copy.review(changes: nil) == "Review changes…")
        #expect(
            Copy.answeredWithAVersion(["Codex", "Claude Code", "Gemini CLI"])
                == "All three answered with a version, so all three start ticked.")
        #expect(
            Copy.findsItAt + " /Applications/Agent Tooling.app" + Copy.ifItMoves
                == "Your apps find Agent Tooling at /Applications/Agent Tooling.app; if it moves, Checkup says the command was not found.")
    }

    /// Plan §6's sentences for Let your apps ask, and the ones this screen
    /// adds for states the fragment names but does not word (O6).
    @Test func letYourAppsAsksNewSentences() {
        #expect(
            Copy.connectedToAnotherCopy(at: "/Users/example/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp")
                == "Connected to another copy at /Users/example/Downloads/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp")
        #expect(Copy.connectedToAnotherCopy(at: "") == "Connected to another copy")
        #expect(Copy.notOurs == "Agent Tooling did not add this one, so it is left alone.")
        #expect(
            Copy.replaceNote(app: "Claude Code")
                == "If adding fails, agent-tooling is left removed from Claude Code; Apps will offer to add it again.")
        #expect(Copy.notChecked == "Not checked on this Mac yet")
        #expect(Copy.notManaged == "Not managed on this Mac")
        #expect(Copy.answeredWithAVersion([]) == nil)
        #expect(Copy.answeredWithAVersion(["Codex"]) == "Codex answered with a version, so it starts ticked.")
        #expect(Copy.answeredWithAVersion(["Codex", "Claude Code"]) == "Both answered with a version, so both start ticked.")
        #expect(Copy.skippedNoApps == "No app is managed here, so Agent Tooling’s own connection was not set up.")
    }

    /// The explainer lists exactly the helper's tools, in the fragment's
    /// words and order, and its counts are theirs.
    @Test func theExplainerListsTheHelpersOwnTools() {
        #expect(
            AgentToolingConnection.lookUpTools.map(\.words) == [
                "Search your library", "Read one tool’s details", "See each app’s status", "See an app’s settings in effect",
                "List what was installed", "Read one receipt", "List requests waiting for you", "Check one request",
                "Link to a review in Agent Tooling",
            ])
        #expect(
            AgentToolingConnection.askTools.map(\.words) == [
                "Ask to add a connection", "Ask to create a skill", "Ask to install a skill", "Ask to install a plugin",
                "Ask to remove a tool",
            ])
        #expect(Copy.canLookUp(AgentToolingConnection.lookUpTools.count) == "Can look up · 9")
        #expect(Copy.canOnlyAsk(AgentToolingConnection.askTools.count) == "Can only ask · 5")
    }

    /// Each app's command is its own tool's `mcp add` at user scope, with the
    /// path quoted for its space; a row too narrow for it keeps the command
    /// and elides the middle of the path, as the fragment draws Claude Code's
    /// and Gemini CLI's.
    @Test func eachRowsCommandIsTheShapeItsAppTakes() {
        let helper = "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp"
        func lines(_ client: ClientKind) -> [String] {
            AgentToolingHookUp.commandLines(
                executable: ClientExecutableLocator.executableName(for: client),
                arguments: AgentToolingConnection.previewArguments(client: client, helperPath: helper), helperPath: helper)
        }

        #expect(
            lines(.codex).first == #"codex mcp add agent-tooling -- "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp""#)
        #expect(
            lines(.claude).first
                == #"claude mcp add --transport stdio --scope user agent-tooling -- "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp""#
        )
        #expect(
            lines(.claude).contains(
                #"claude mcp add --transport stdio --scope user agent-tooling -- "/Applications/…/Helpers/agent-tooling-mcp""#))
        #expect(
            lines(.gemini).contains(
                #"gemini mcp add --scope user --transport stdio agent-tooling -- "/Applications/…/Helpers/agent-tooling-mcp""#))
        #expect(
            lines(.kiro).first
                == #"kiro-cli mcp add --name agent-tooling --command "/Applications/Agent Tooling.app/Contents/Helpers/agent-tooling-mcp" --scope global --force"#
        )
        #expect(lines(.codex).allSatisfy { $0.hasPrefix("codex mcp add agent-tooling -- \"/Applications/") })
    }

    /// What VoiceOver reads for a row with nothing to tick.
    @Test func aRowWithNothingToTickReadsAsOnePhrase() {
        #expect(Copy.rowLabel("Kiro CLI", Copy.notFound) == "Kiro CLI, not found on this Mac")
        #expect(Copy.rowLabel("Claude Code", Copy.alreadyConnected) == "Claude Code, already connected")
        #expect(Copy.explainerLabel == "What your apps can look up, and what they can only ask for")
    }
}

import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// Start your library's words (S08), verbatim from its fragment
/// (`06-s08-library.html`) and the plan's new copy (§6), so a change to any
/// of them is a decision someone makes on purpose. The strings the fragment
/// does not draw are new copy, listed for the owner in the package's progress
/// file, and pinned here all the same.
@Suite("Launchpad library wording")
@MainActor
struct LaunchpadLibraryWordingTests {
    private typealias Copy = LaunchpadCopy.Library

    @Test func theHeaderReadsAsDrawn() {
        #expect(Copy.eyebrow == "Your library")
        #expect(Copy.title == "Start your library")
        #expect(
            Copy.subtitle
                == "Make the skills you already have yours, and add a few tools if you like. The apps’ folders are not changed; installing comes later, in one review."
        )
    }

    @Test func makeYourSkillsYoursReadsAsDrawn() {
        #expect(Copy.makeYoursHeading == "Make your skills yours")
        #expect(Copy.addAll(3) == "Add all 3 to library")
        #expect(Copy.addAll(1) == "Add to library")
        #expect(Copy.onlyIn("Claude Code") == "Only in Claude Code")
        #expect(
            Copy.differentCopies(LaunchpadCopy.list(["Codex", "Claude Code"]))
                == "Codex and Claude Code have different copies. Choose which copy to bring in:")
        #expect(Copy.sameIn(LaunchpadCopy.list(["Codex", "Claude Code"])) == "Same in Codex and Claude Code")
        #expect(Copy.copy(in: "Codex") == "Codex’s copy")
        #expect(Copy.copy(in: "Claude Code") == "Claude Code’s copy")
        #expect(Copy.copyDetail(files: 2, changed: "Aug 14") == "2 files · changed Aug 14")
        #expect(Copy.copyDetail(files: 3, changed: "Oct 2") == "3 files · changed Oct 2")
        #expect(Copy.copyDetail(files: 1, changed: nil) == "1 file")
        #expect(
            Copy.otherCopyIsOlder(in: "Codex", files: 2, changed: "Aug 14")
                == "Codex’s copy is older (2 files, Aug 14). It stays in Codex either way.")
    }

    /// The chooser's caption where the fragment draws none: the other copy
    /// newer, dates that say nothing, and more than one other copy.
    @Test func theChoosersOtherCaptionsReadAsWritten() {
        #expect(
            Copy.otherCopyIsNewer(in: "Claude Code", files: 3, changed: "Oct 2")
                == "Claude Code’s copy is newer (3 files, Oct 2). It stays in Claude Code either way.")
        #expect(Copy.otherCopyStays(in: "Codex") == "Codex’s copy stays in Codex either way.")
        #expect(Copy.otherCopiesStay == "The other copies stay where they are either way.")
    }

    @Test func theStatesReadAsTheFragmentNotesThem() {
        #expect(Copy.adding == "Adding…")
        #expect(Copy.personalLibrary == "Personal library")
        #expect(
            Copy.calledOtherwise(recorded: "frontend-design", found: "frontend-ui")
                == "Its SKILL.md calls it frontend-ui, not frontend-design, so it cannot be added yet. Rename one to match.")
        #expect(
            Copy.sentence(for: .declaredNameMismatch(ArtifactID(), recorded: "frontend-design", found: "frontend-ui"))
                == "Its SKILL.md calls it frontend-ui, not frontend-design, so it cannot be added yet. Rename one to match.")
        #expect(Copy.keptInStep(by: "Example Manager") == "Kept in step by Example Manager — left alone")
        #expect(Copy.offline(readOn: "Oct 16") == "Showing what was read Oct 16. skills.sh could not be reached.")
        #expect(Copy.inLibrary == "In library")
        #expect(Copy.needsGit == "Needs Git")
        #expect(LaunchpadCopy.Footer.continue == "Continue", "nothing to make yours: the primary reads Continue")
    }

    /// Section A's one line, in its two cases.
    @Test func nothingToMakeYoursReadsAsWritten() {
        #expect(Copy.nothingToMakeYours == "Your apps hold no skills of their own to bring in.")
        #expect(Copy.everythingIsYours == "Every skill your apps hold is in your library already.")
    }

    /// Every reason a row is refused, about "it" beside the row's name, and
    /// led by the skill's name where nothing beside it says which.
    @Test func everyRowRefusalReadsAsWritten() {
        let id = ArtifactID()
        let cases: [(LibraryAdditionRefusal, String, String)] = [
            (
                .declaredNameMismatch(id, recorded: "frontend-design", found: "frontend-ui"),
                "Its SKILL.md calls it frontend-ui, not frontend-design, so it cannot be added yet. Rename one to match.",
                "Frontend Design’s SKILL.md calls it frontend-ui, not frontend-design, so it cannot be added yet. Rename one to match."
            ),
            (
                .notAdoptable(id, .missing), "It is no longer in your library. Check your apps again.",
                "Frontend Design is no longer in your library. Check your apps again."
            ),
            (.notAdoptable(id, .alreadyYours), "It is in your library already.", "Frontend Design is in your library already."),
            (
                .notAdoptable(id, .notALooseSkill), "It comes with a plugin, so it stays with its plugin.",
                "Frontend Design comes with a plugin, so it stays with its plugin."
            ),
            (
                .notAdoptable(id, .notRead), "This copy could not be read, so it cannot be added yet.",
                "Frontend Design’s copy could not be read, so it cannot be added yet."
            ),
            (
                .notAdoptable(id, .followsAnUpstream), "This copy follows a repository, so it is added from Discover instead.",
                "Frontend Design’s copy follows a repository, so it is added from Discover instead."
            ),
        ]
        for (refusal, beside, named) in cases {
            #expect(Copy.sentence(for: refusal) == beside)
            #expect(Copy.sentence(for: refusal, naming: "Frontend Design") == named)
        }
        #expect(Copy.notAdded() == "It could not be added to your library.")
    }

    /// Why a copy could not be read before it was offered, for each way
    /// reading it fails.
    @Test func everyUnreadableCopyReadsAsWritten() {
        #expect(
            Copy.sentence(forUnreadable: WorkspaceSkillPreparationError.missingSkillDefinition)
                == "This folder has no SKILL.md, so it is not a skill to add.")
        #expect(
            Copy.sentence(forUnreadable: WorkspaceSkillPreparationError.invalidSkillDefinition)
                == "Its SKILL.md does not say what the skill is called and what it does, so it cannot be added yet.")
        #expect(
            Copy.sentence(forUnreadable: WorkspaceSkillPreparationError.pluginPackageRoot)
                == "This folder is a plugin, so it stays with its plugin.")
        #expect(
            Copy.sentence(forUnreadable: WorkspaceSkillPreparationError.invalidUpstream)
                == "This copy could not be read, so it cannot be added yet.")
        #expect(
            Copy.sentence(forUnreadable: CocoaError(.fileReadNoPermission))
                == "This copy could not be read, so it cannot be added yet.")
    }

    @Test func fromYourAppsCatalogsReadsAsDrawn() throws {
        #expect(Copy.catalogsHeading == "From your apps’ catalogs")
        #expect(Copy.writeYourOwn == "Write your own…")
        #expect(Copy.pasteCommand == "Paste a command or URL…")
        let entries = try StarterShelf.entries()
        #expect(
            entries.map { "\($0.name) | \($0.summary) | \($0.source)" } == [
                "Supabase | Supabase database, auth and storage from Claude Code. | Claude Code’s catalog",
                "Vercel | Deploy and inspect Vercel projects. | Claude Code’s catalog",
                "GitHub for Codex | GitHub issues and pull requests in Codex. | Codex’s catalog · separate from Claude Code’s GitHub",
                "MCP Builder | Guides building an MCP server. | skills.sh · anthropics/skills",
            ])
        #expect(Copy.source("skills.sh · anthropics/skills", installs: 12_400) == "skills.sh · anthropics/skills · 12.4k installs")
        #expect(Copy.source("skills.sh · anthropics/skills", installs: 1) == "skills.sh · anthropics/skills · 1 install")
        #expect(Copy.skillsShUnreachable == "skills.sh could not be reached.")
        #expect(
            Copy.finePrint(example: ("Triage Issue", "Sentry"))
                == "Skills inside plugins, like Triage Issue in Sentry, stay with their plugin. Skills you leave stay where they are, and Checkup keeps listing them."
        )
        #expect(
            Copy.finePrint(example: nil)
                == "Skills inside plugins stay with their plugin. Skills you leave stay where they are, and Checkup keeps listing them.")
    }

    /// A card the last Add left out: "Not added" on its last line, and a
    /// sentence under the cards that names it and speaks for it alone.
    @Test func everyCardRefusalReadsAsWritten() {
        #expect(Copy.notAddedMark == "Not added")
        #expect(Copy.notFetched("MCP Builder") == "MCP Builder could not be fetched from its repository, so it was not added.")
        #expect(
            Copy.namesNoRepository("MCP Builder") == "MCP Builder’s listing names no repository to fetch it from, so it was not added.")
        #expect(Copy.notAdded(naming: "MCP Builder") == "MCP Builder could not be added to your library.")
        let match = NativePackageAdoption.Match(artifactID: ArtifactID(), displayName: "Supabase", reason: .nativeRoute)
        #expect(Copy.sentence(forListing: .alreadyInLibrary(match), naming: "Supabase") == "Supabase is in your library already.")
        #expect(Copy.sentence(forListing: .identityCollision, naming: "Supabase") == "Supabase is in your library already.")
        #expect(
            Copy.sentence(forListing: .previouslyRemoved, naming: "Vercel")
                == "Vercel was not added. You removed this package from your library before. Add it back from the library rather than from a catalog listing."
        )
        #expect(
            Copy.sentence(forListing: .unrecognizedListing, naming: "Vercel")
                == "Vercel was not added. This listing does not carry the package identity its catalog records, so it cannot be added by name."
        )
        let id = ArtifactID()
        #expect(
            Copy.sentence(for: .catalog(id, .previouslyRemoved), naming: "Vercel")
                == Copy.sentence(forListing: .previouslyRemoved, naming: "Vercel"))
        #expect(
            Copy.sentence(for: .intake(id, .upstreamAlreadyManaged), naming: "MCP Builder") == "MCP Builder is in your library already.")
        #expect(Copy.sentence(for: .intake(id, .identityCollision), naming: "MCP Builder") == "MCP Builder is in your library already.")
        #expect(
            Copy.sentence(for: .intake(id, .sourceIdentityConflict), naming: "MCP Builder") == "MCP Builder is in your library already.")
        #expect(
            Copy.sentence(for: .intake(id, .reviewMismatch), naming: "MCP Builder") == "MCP Builder could not be added to your library.")
    }

    @Test func theFooterCountsWhatIsTickedOrPicked() {
        #expect(Copy.add(3) == "Add 3 to library")
        #expect(Copy.add(1) == "Add 1 to library")
    }

    /// The plan's new copy (§6): what the review's library row and Done say
    /// for a skill written or pasted on this screen.
    @Test func theDecisionsLinesForTheSheetsReadAsPlanned() {
        #expect(LaunchpadCopy.Review.addedWrittenHere("Code Review") == "Added Code Review, written here")
        #expect(LaunchpadCopy.Review.addedFromPastedCommand("Linear") == "Added Linear, from a pasted command")
        var decisions = LaunchpadLibraryDecisions()
        decisions.added = [
            .init(artifactID: ArtifactID(), name: "Code Review", source: .written),
            .init(artifactID: ArtifactID(), name: "Linear", source: .pasted),
        ]
        #expect(decisions.lines == ["Added Code Review, written here", "Added Linear, from a pasted command"])
    }

    /// Write your own… over the stage, where putting the skill in apps is
    /// the stage's next step.
    @Test func theEditorOverTheStagePointsAtPutInApps() {
        #expect(
            Copy.editorPlacement
                == "Saving adds the skill to your library. Which apps use it is chosen in the next step, Put in apps.")
        #expect(Copy.editorNext == "Put in apps, the next step")
        #expect(LaunchpadCopy.Footer.stepPutInApps == "Put in apps", "the step the editor names, as the footer names it")
    }

    @Test func voiceOverHearsWhatEachControlIs() {
        #expect(Copy.chooserLabel("Frontend Design") == "Copy of Frontend Design to bring in")
        #expect(Copy.copyLabel(in: "Codex", files: 2, changed: "Aug 14") == "Codex’s copy, 2 files, changed Aug 14")
        #expect(Copy.inApps(LaunchpadCopy.list(["Codex", "Claude Code", "Gemini CLI"])) == "In Codex, Claude Code and Gemini CLI")
        #expect(
            Copy.cardLabel(
                name: "Supabase", summary: "Supabase database, auth and storage from Claude Code.", source: "Claude Code’s catalog")
                == "Supabase, Supabase database, auth and storage from Claude Code. Claude Code’s catalog")
    }

    @Test func everyFailureReadsAsWrittenAndSaysNothingWasChanged() {
        let failures = Copy.Failures.self
        #expect(
            failures.notAdded(["Release Notes", "Supabase"])
                == "Release Notes and Supabase could not be added to your library. Nothing was changed.")
        #expect(failures.notAdded(["Release Notes"]) == "Release Notes could not be added to your library. Nothing was changed.")
        #expect(failures.nameTaken == "Your library already has a skill with that name. Choose another name. Nothing was changed.")
        #expect(
            failures.contentUnreachable
                == "This library cannot reach its stored content, so the skill was not saved. Nothing was changed.")
        #expect(failures.libraryMoved == "Your library changed while this was open. Create the skill again. Nothing was changed.")
        #expect(failures.notAnIdentifier == "Use lowercase letters, numbers and single hyphens for the name. Nothing was changed.")
        #expect(
            failures.incompleteDefinition
                == "The definition does not say what the skill is called and what it does. Nothing was changed.")
        #expect(failures.notSaved == "That skill could not be saved to your library. Nothing was changed.")
    }

    /// Checkup's refusal of one skill reads as Start your library's does,
    /// led by the skill's name.
    @Test func checkupWordsARefusalAsTheStageDoesByName() {
        let mismatch = SetupAdoptionRefusal(
            refusal: .declaredNameMismatch(ArtifactID(), recorded: "frontend-design", found: "frontend-ui"), name: "Frontend Design")
        #expect(
            mismatch.errorDescription == Copy.calledOtherwise(recorded: "frontend-design", found: "frontend-ui", naming: "Frontend Design"))
        let yours = SetupAdoptionRefusal(refusal: .notAdoptable(ArtifactID(), .alreadyYours), name: "Release Notes")
        #expect(yours.errorDescription == "Release Notes is in your library already.")
        let unnamed = SetupAdoptionRefusal(refusal: .notAdoptable(ArtifactID(), .alreadyYours), name: nil)
        #expect(unnamed.errorDescription == "It is in your library already.")
    }
}

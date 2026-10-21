import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The words of Your other Macs (S17), Join (J01, V08, Finish joining) and You
/// joined (J02), pinned to the fragments and plan §6, and the copy derived
/// from something else checked against it: the read counts against the
/// manifest, the sign-in variables against the shell probe's list, and the
/// travels line against what a Mac's status file carries.
@Suite("Launchpad macs wording")
@MainActor
struct LaunchpadMacsWordingTests {
    @Test func yourOtherMacsReadsAsTheFragmentDrawsIt() {
        let copy = LaunchpadCopy.Macs.self
        #expect(copy.eyebrow == "Other Macs")
        #expect(copy.title == "Use your library on your other Macs")
        #expect(
            copy.subtitle
                == "Connect a private Git repository your other Macs can read. Agent Tooling publishes this Mac’s library there.")
        #expect(copy.addressLabel == "Repository address")
        #expect(copy.branchLabel == "Branch")
        #expect(copy.nameLabel == "This Mac’s name")
        #expect(copy.addressPlaceholder == "https://github.com/you/agent-tooling-workspace.git")
        #expect(copy.httpsAddress == "An HTTPS address")
        #expect(copy.travelsTitle == "What travels")
        #expect(copy.travelsLibrary == "Your library and where each tool goes")
        #expect(copy.travelsSkillFiles == "Your own skills’ files")
        #expect(
            copy.travelsStatus
                == "Each Mac’s status: app versions, item counts, names of pending items, the sign-in method and plan, and a salted account fingerprint"
        )
        #expect(copy.staysTitle == "What stays on this Mac")
        #expect(copy.staysChoices == "Which apps it manages and its update choices")
        #expect(copy.staysProjects == "Project folders")
        #expect(copy.staysKeys == "Passwords and keys: Git uses the sign-in it already has")
        #expect(copy.warning == "A repository is not encrypted storage. Anyone with access to it can read what is published there.")
        #expect(copy.notNow == "Not now")
        #expect(copy.skipForNow == "Skip for now")
        #expect(copy.connectAndShare == "Connect and share")
        #expect(copy.connecting == "Connecting…")
        #expect(copy.publishing == "Publishing…")
        #expect(copy.sharedFirstTime == "Shared this Mac’s setup for the first time.")
        #expect(copy.joinNext == "On your other Mac, open Agent Tooling and choose Join.")
        #expect(copy.use("https://github.com/you/agent-tooling-workspace.git") == "Use https://github.com/you/agent-tooling-workspace.git")
        #expect(copy.nameTaken("Juniper", savedAs: "Juniper 2") == "Another Mac is called Juniper, so this Mac is saved as Juniper 2.")
        #expect(LaunchpadCopy.Footer.publishing == copy.publishing)
    }

    /// The words S17 adds beyond the fragment (plan §6, owner flag O6).
    @Test func yourOtherMacsNewWords() {
        let copy = LaunchpadCopy.Macs.self
        #expect(copy.tryAgain == "Try again")
        #expect(copy.alreadyConnected == "This Mac already shares its library through this repository.")
        #expect(copy.alreadySharesThroughFolder == "This Mac already shares its library through a folder.")
        #expect(copy.Failures.unavailable(nil) == "This Mac cannot connect a repository now. Nothing was changed.")
        #expect(copy.Failures.unavailable("") == "This Mac cannot connect a repository now. Nothing was changed.")
        #expect(
            copy.Failures.unavailable("The sync folder is not writable.")
                == "This Mac cannot connect a repository now. The sync folder is not writable. Nothing was changed.")
    }

    /// What VoiceOver hears as a card says why a form stopped: S17's check,
    /// its refused publish, V08, and a join that stopped after its store.
    @Test func eachStoppedFormIsAnnounced() {
        let unreachable = GitRemoteProblem.unreachable(host: "github.com")
        #expect(
            StageBanner.spoken(title: LaunchpadSyncConnect.title(for: unreachable), message: unreachable.errorDescription ?? "")
                == "Couldn’t reach that repository. Git could not reach github.com from this Mac. Check the network connection, then try again. Nothing was changed."
        )
        let refused = GitRemoteProblem.pushRefused(host: "github.com")
        #expect(
            StageBanner.spoken(title: LaunchpadSyncConnect.title(for: refused), message: refused.errorDescription ?? "")
                == "Couldn’t publish there. github.com did not accept what this Mac published. Check that your Git sign-in can write to it. Nothing was changed."
        )
        let typo = GitRemoteProblem.notFound(host: "github.com")
        #expect(
            StageBanner.spoken(title: LaunchpadJoin.title(for: typo), message: typo.errorDescription ?? "")
                == "Couldn’t reach that repository. github.com has no repository at this address that this Mac can see. Check the spelling, or your Git sign-in for github.com. Nothing was changed."
        )
        let join = LaunchpadCopy.Join.self
        #expect(
            StageBanner.spoken(title: join.stoppedTitle, message: join.stoppedMessage)
                == WorkspaceJoinError.lateFailure(workspaceID: WorkspaceObjectID()).errorDescription)
        #expect(StageBanner.spoken(title: join.couldNotJoin, message: "") == "Couldn’t join")
    }

    /// S17's travels line names everything a Mac's status file carries, so
    /// nothing is implied to stay on this Mac that travels. A field added to
    /// the status file must be named here, or listed as bookkeeping.
    @Test func theTravelsLineNamesEverythingAStatusCarries() {
        let line = LaunchpadCopy.Macs.travelsStatus
        let phrase: [String: String] = [
            "apps": "app versions", "pending": "names of pending items", "accounts": "the sign-in method and plan",
        ]
        let bookkeeping: Set<String> = ["formatVersion", "deviceID", "name", "lastScan", "publishedAt", "revisionID"]
        let status = PublishedDeviceStatus(
            deviceID: WorkspaceObjectID(), name: "Juniper", lastScan: nil, apps: [], pending: [], revisionID: WorkspaceObjectID())
        for label in Mirror(reflecting: status).children.compactMap(\.label) where !bookkeeping.contains(label) {
            let words = phrase[label]
            #expect(words.map(line.contains) == true, "the travels line does not name \(label)")
        }
        let app = PublishedDeviceStatus.AppSummary(
            surface: .codexCLI, installed: true, version: "0.164.0", skillCount: 2, pluginCount: 1, mcpServerCount: 2)
        let appPhrases: [String: String] = [
            "version": "app versions", "skillCount": "item counts", "pluginCount": "item counts", "mcpServerCount": "item counts",
        ]
        for label in Mirror(reflecting: app).children.compactMap(\.label) where !["surface", "installed"].contains(label) {
            #expect(appPhrases[label].map(line.contains) == true, "the travels line does not name an app's \(label)")
        }
        // An account's sign-in: its method and plan (and what overrides the
        // method in the shell), its item counts and switches, and the salted
        // fingerprint; never an address.
        let account = PublishedAccountSummary(
            provider: .chatGPT, signInMethod: .subscription, plan: "plus", accountFingerprint: "f", itemCounts: nil,
            switchesOutOfStep: nil, shellOverrides: nil, observedAt: ClientHomeFixture.now)
        let accountPhrases: [String: String] = [
            "provider": "the sign-in method", "signInMethod": "the sign-in method", "plan": "plan",
            "accountFingerprint": "a salted account fingerprint", "itemCounts": "item counts", "switchesOutOfStep": "item counts",
            "shellOverrides": "the sign-in method",
        ]
        for label in Mirror(reflecting: account).children.compactMap(\.label) where label != "observedAt" {
            #expect(accountPhrases[label].map(line.contains) == true, "the travels line does not name an account's \(label)")
        }
    }

    @Test func joinReadsAsTheFragmentDrawsIt() {
        let copy = LaunchpadCopy.Join.self
        #expect(copy.eyebrow == "Join")
        #expect(copy.title == "Join your library")
        #expect(
            copy.subtitle
                == "Paste the repository address from Settings › Sync on your other Mac. Git uses the sign-in it already has; Agent Tooling never asks for a password."
        )
        #expect(copy.appsLabel == "This Mac’s apps")
        #expect(copy.readsOnlyThese == "Joining reads only these")
        #expect(copy.reads(places: 9, commands: 8) == "Reads 9 places and runs 8 commands here")
        #expect(copy.reads(places: 1, commands: 1) == "Reads 1 place and runs 1 command here")
        #expect(copy.whatItReads == "What it reads…")
        #expect(copy.notFound("Gemini CLI") == "Gemini CLI · Not found")
        #expect(copy.readsList == "Reads")
        #expect(copy.runsList == "Runs")
        #expect(copy.signInList == "How your apps sign in")
        #expect(copy.shellVariablesOnly(12) == "(names of 12 sign-in variables only)")
        #expect(copy.fetchesAfter == "Then Git fetches your library into Agent Tooling’s own folder.")
        #expect(
            copy.consent(mac: "Cedar")
                == "Joining reads what these apps hold on Cedar, the same places a new library reads. Nothing is installed until you review it."
        )
        // Until this Mac's name has been read (NEW, O6).
        #expect(
            copy.consent(mac: nil)
                == "Joining reads what these apps hold on this Mac, the same places a new library reads. Nothing is installed until you review it."
        )
        #expect(copy.registering(nil) == "Registering this Mac")
        #expect(copy.joinUnnamed == "Join")
        #expect(copy.beforeJoining == "Before joining")
        #expect(copy.gitInstalled == "Git is installed")
        #expect(copy.answered(host: "github.com") == "github.com answered")
        #expect(copy.holdsLibrary(tools: 13) == "It holds a library (13 tools)")
        #expect(copy.holdsLibrary == "It holds a library")
        #expect(copy.buildCanRead == "This build can read it")
        #expect(copy.joining == "Joining")
        #expect(copy.reachingRepository == "Reaching the repository")
        #expect(copy.readingLibrary(tools: 13) == "Reading your library (13 tools)")
        #expect(copy.checkingApps == "Checking this Mac’s apps")
        #expect(copy.registering("Cedar") == "Registering “Cedar”")
        #expect(copy.sharing == "Sharing")
        #expect(copy.joinAs("Cedar") == "Join as Cedar")
        #expect(copy.joinAs("Cedar 2") == "Join as Cedar 2")
        #expect(copy.joiningBusy == "Joining…")
    }

    @Test func aTypoReadsAsV08DrawsIt() {
        let copy = LaunchpadCopy.Join.self
        let problem = GitRemoteProblem.notFound(host: "github.com")
        #expect(LaunchpadJoin.title(for: problem) == "Couldn’t reach that repository")
        #expect(
            problem.errorDescription
                == "github.com has no repository at this address that this Mac can see. Check the spelling, or your Git sign-in for github.com. Nothing was changed."
        )
        #expect(copy.notCheckedYet == "Not checked yet")
        #expect(copy.notStarted == "Not started")
        #expect(copy.tryAgain == "Try again")
        // Other causes, each in its own words.
        #expect(
            GitRemoteProblem.signInFailed(host: "github.com").errorDescription
                == "Git could not sign in to github.com from this Mac. Nothing was changed.")
        #expect(
            GitRemoteProblem.newerFormat.errorDescription
                == "This library needs a newer Agent Tooling. Update this Mac first. Nothing was changed.")
        #expect(LaunchpadJoin.title(for: .newerFormat) == "This build can’t read it")
        #expect(LaunchpadJoin.title(for: .emptyRemote) == "No library to join there")
        #expect(LaunchpadJoin.title(for: .gitMissing) == "Git is not installed")
    }

    /// Plan §6: Finish joining's words are the join's own late failure.
    @Test func finishJoiningReadsAsPlannedAndAsTheJoinSaysIt() {
        let copy = LaunchpadCopy.Join.self
        #expect(copy.finishJoining == "Finish joining")
        #expect(
            "\(copy.stoppedTitle). \(copy.stoppedMessage)"
                == "Joining stopped before it finished. Finish joining completes it; nothing in your apps changes.")
        #expect(
            "\(copy.stoppedTitle). \(copy.stoppedMessage)"
                == WorkspaceJoinError.lateFailure(workspaceID: WorkspaceObjectID()).errorDescription)
        #expect(copy.nothingToFinishTitle == "There is nothing to finish")
    }

    @Test func youJoinedReadsAsTheFragmentDrawsIt() {
        let copy = LaunchpadCopy.Join.self
        #expect(copy.joinedAs("Cedar") == "You joined as Cedar")
        #expect(copy.skillsCameAcross(2) == "2 of your own skills came across.")
        #expect(copy.rename == "Rename…")
        #expect(copy.renameTitle == "This Mac’s name")
        #expect(copy.renameConfirm == "Rename")
        #expect(copy.cancel == "Cancel")
        #expect(
            copy.otherMacLine(name: "Juniper", published: "6 min ago", apps: [("Codex", "0.164.0"), ("Claude Code", "2.1.304")])
                == "Juniper · published 6 min ago · Codex 0.164.0 · Claude Code 2.1.304")
        #expect(copy.sameLibrary(tools: 13) == "Same library · 13 tools")
        #expect(copy.otherMac == "other Mac")
        #expect(copy.thisMac(family: "Mac mini", systemVersion: 26) == "Mac mini · macOS 26 · this Mac")
        #expect(copy.shares("Juniper", tools: 3) == "Juniper shares 3 tools with every Mac")
        #expect(copy.policy == "Nothing from another Mac installs here until you press Install.")
        #expect(copy.policy == OverviewView.incomingFooter(automatic: []))
        #expect(copy.into(["Codex", "Claude Code"]) == "Into Codex and Claude Code")
        #expect(copy.into(["Claude Code"]) == "Into Claude Code")
        #expect(copy.installs(2) == "2 installs")
        #expect(copy.installs(1) == "1 install")
        #expect(copy.ownConnection == "Agent Tooling’s own connection")
        #expect(copy.setUpOn(["Juniper"]) == "Set up on Juniper only")
        #expect(copy.setUpHereToo == "Set up on this Mac too")
        #expect(copy.setUpHere == "Set up on this Mac")
        #expect(copy.connectHereToo == "Connect it here too")
        #expect(copy.installLater == "Install later")
        #expect(copy.installLaterHelp == "They stay on Home under From your other Macs.")
        #expect(copy.review(5) == "Review 5 changes…")
        #expect(copy.review(1) == "Review 1 change…")
        #expect(copy.checkingShared("Juniper") == "Checking what Juniper shares…")
        #expect(copy.whatIsShared("Juniper") == "What Juniper shares with every Mac")
        #expect(copy.noVerifiedCopy == "No verified copy in your library yet")
        // When what arrived could not be worked out, or a rename has to wait
        // (NEW, O6).
        #expect(
            copy.Failures.notWorkedOut("Juniper", reason: "A destination folder on this Mac could not be read. Nothing was changed.")
                == "Agent Tooling could not work out what Juniper shares here. A destination folder on this Mac could not be read. Nothing was changed."
        )
        #expect(
            copy.Failures.notWorkedOut("Juniper", reason: "Check your apps again.")
                == "Agent Tooling could not work out what Juniper shares here. Check your apps again. Nothing was changed.")
        #expect(
            copy.Failures.notWorkedOut("Juniper", reason: nil)
                == "Agent Tooling could not work out what Juniper shares here. Nothing was changed.")
        #expect(
            copy.Failures.renameWhileSharing
                == "This Mac is sharing with your other Macs. Rename it again in a moment. Nothing was changed.")
        // Navigation takes no ellipsis; what opens a popover or a review does.
        #expect(!copy.connectHereToo.hasSuffix("…"))
        #expect(!copy.installLater.hasSuffix("…"))
    }

    /// How long ago another Mac published, in the line's own units.
    @Test func publishedTimesReadInMinutesAndHours() {
        let now = ClientHomeFixture.now
        let copy = LaunchpadCopy.Join.self
        #expect(copy.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(copy.ago(now.addingTimeInterval(-6 * 60), now: now) == "6 min ago")
        #expect(copy.ago(now.addingTimeInterval(-2 * 3_600), now: now) == "2 hr ago")
        #expect(copy.ago(now.addingTimeInterval(-30 * 3_600), now: now) == "yesterday")
    }

    /// The counts Join shows are the manifest's, and the sign-in variables
    /// are the shell probe's own list (public build: Cedar's 9 and 8).
    @Test func theDerivedCountsComeFromWhereTheyAreRead() async throws {
        let home = try ClientHomeFixture(.cedar)
        defer { home.remove() }
        let manifest = FirstReadManifest.build(chosen: home.found, homeURL: home.url, includeProjectHistory: false)
        #expect(
            LaunchpadCopy.Join.reads(places: manifest.placeCount, commands: manifest.commandCount)
                == "Reads 9 places and runs 8 commands here")
        #expect(LaunchpadCopy.Join.shellVariablesOnly(AccountShellOverride.allCases.count) == "(names of 12 sign-in variables only)")
    }

    /// What VoiceOver hears for the strip's tiles and the list's lines.
    @Test func theSpokenLabels() {
        let copy = LaunchpadCopy.Join.self
        #expect(copy.tileLabel("Codex", found: true, chosen: true) == "Codex, found, read when joining")
        #expect(copy.tileLabel("Kiro CLI", found: false, chosen: false) == "Kiro CLI, not found, not read")
        #expect(copy.tileHint("Command-1", chosen: true) == "Command-1 leaves it out.")
        #expect(copy.tileHint("Command-4", chosen: false) == "Command-4 reads it too.")
        #expect(copy.tilesLabel(chosen: ["Codex", "Claude Code"]) == "Joining reads Codex and Claude Code")
        #expect(ProgressStepList.spoken(.init(id: "a", title: "Git is installed", state: .done)) == "Git is installed, done")
        #expect(
            ProgressStepList.spoken(.init(id: "b", title: "Checking this Mac’s apps", state: .running))
                == "Checking this Mac’s apps, under way")
        #expect(
            ProgressStepList.spoken(.init(id: "c", title: "It holds a library", state: .notChecked))
                == "It holds a library, not checked yet")
        #expect(ProgressStepList.spoken(.init(id: "d", title: "Sharing", state: .waiting(5))) == "Sharing, not started")
        #expect(
            copy.macsLabel(other: "Juniper", this: "Cedar", tools: 13)
                == "Juniper, other Mac, and Cedar, this Mac: the same library of 13 tools")
        #expect(
            LaunchpadCopy.Macs.sharedAnnouncement(LaunchpadCopy.Macs.sharedFirstTime)
                == "Shared this Mac’s setup for the first time. On your other Mac, open Agent Tooling and choose Join.")
    }
}

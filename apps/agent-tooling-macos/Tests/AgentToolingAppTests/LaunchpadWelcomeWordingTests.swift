import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The words WP0c owns, pinned: Welcome's, from its fragment
/// (`02-s01-welcome.html`); the unreadable screen's, from plan §6; the
/// menu-bar item's while setup owns the app; the window's title; and the
/// re-entry command's two placements.
@Suite("Launchpad welcome wording")
@MainActor
struct LaunchpadWelcomeWordingTests {
    @Test func welcomeSaysWhatEachWayOnDoes() {
        let copy = LaunchpadCopy.Welcome.self
        #expect(copy.title == "Welcome to Agent Tooling")
        #expect(copy.subtitle == "Is this your first Mac, or does another Mac already have your library?")
        #expect(copy.startTitle == "Start a library on this Mac")
        #expect(copy.startDetail == "Reads this Mac’s apps. Nothing is installed.")
        #expect(copy.joinTitle == "Join your library from another Mac")
        #expect(copy.joinDetail == "Paste the address from Settings › Sync on that Mac.")
        #expect(copy.footnote == "A Mac that starts its own library cannot join another later.")
        #expect(copy.version("0.1.0") == "Agent Tooling 0.1.0")
        #expect(copy.startPrimary == "Start here")
        #expect(copy.joinPrimary == "Join")
        #expect(copy.openingWorkspace == "Opening your workspace…")
    }

    /// The rows in order, each read as its choice with what it does as the
    /// hint: Start here's first, with the laptop; Join's second, with the
    /// arrows B and C give Join.
    @Test func welcomesRowsAreInOrder() {
        let rows = LaunchpadWelcomeScreen.rows
        #expect(rows.map(\.path) == [.startHere, .join])
        #expect(rows.map(\.title) == [LaunchpadCopy.Welcome.startTitle, LaunchpadCopy.Welcome.joinTitle])
        #expect(rows.map(\.detail) == [LaunchpadCopy.Welcome.startDetail, LaunchpadCopy.Welcome.joinDetail])
        #expect(rows.map(\.symbol) == ["laptopcomputer", "arrow.triangle.2.circlepath"])
    }

    /// VoiceOver reads the rows as a choice of two: each as its choice, with
    /// what choosing it does as the hint, and the row the keyboard is on as
    /// the selected one, Start here's until the keyboard moves.
    @Test func welcomesRowsReadAsAChoiceOfTwo() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let choice = LaunchpadWelcomeScreen.choice(flow)
        let rows = LaunchpadWelcomeScreen.rows
        #expect(rows.map(\.accessibilityLabel) == ["Start a library on this Mac", "Join your library from another Mac"])
        #expect(
            rows.map(\.accessibilityHint) == [
                "Reads this Mac’s apps. Nothing is installed.", "Paste the address from Settings › Sync on that Mac.",
            ])
        func selected() -> [Bool] {
            rows.map { WelcomeChoiceRow.traits(isFocused: choice.focused == $0.path).contains(.isSelected) }
        }
        #expect(selected() == [true, false])

        choice.focus(.join)
        #expect(selected() == [false, true])
        #expect(WelcomeChoiceRow.traits(isFocused: false).contains(.isButton))
        #expect(WelcomeChoiceRow.traits(isFocused: true).contains(.isButton))
    }

    /// The footer: Welcome's name, "Set up later ⎋", no Back, no second
    /// button, and the one primary following the row the keyboard is on.
    @Test func welcomesPrimaryFollowsTheKeyboard() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        #expect(flow.info.footerName == "Welcome")
        #expect(flow.info.capsules == nil)
        #expect(flow.info.back == nil)

        let footer = LaunchpadStageView.footer(for: flow)
        #expect(footer.primary?.title == "Start here")
        #expect(footer.primary?.key == .return)
        #expect(footer.secondary == nil)
        #expect(footer.showsBack == false)
        guard case .setUpLater = footer.later else {
            Issue.record("Welcome's later slot is not Set up later")
            return
        }

        LaunchpadWelcomeScreen.choice(flow).focus(.join)
        let joining = LaunchpadStageView.footer(for: flow)
        #expect(joining.primary?.title == "Join")
        joining.primary?.action()
        #expect(flow.path == .join)
        #expect(flow.step == .join)
    }

    @Test func startHereTakesTheFirstRow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let choice = LaunchpadWelcomeScreen.choice(flow)
        choice.focus(.join)
        choice.focus(.startHere)
        // The rerun is no row of Welcome's.
        choice.focus(.rerun)
        #expect(choice.focused == .startHere)

        LaunchpadStageView.footer(for: flow).primary?.action()

        #expect(flow.path == .startHere)
        #expect(flow.step == .apps)
    }

    @Test func theVersionLineReadsTheBundle() throws {
        let folder = try TemporaryFolder("welcome-version")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let bundle = folder.url.appending(path: "Agent Tooling.app", directoryHint: .isDirectory)
        try write(
            bundle.appending(path: "Contents/Info.plist"),
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1.0</string></dict></plist>
            """)

        #expect(LaunchpadWelcomeScreen.version(of: bundle) == "0.1.0")
        #expect(LaunchpadWelcomeScreen.version(of: folder.url.appending(path: "Missing.app")) == nil)
    }

    // MARK: - The unreadable screen

    @Test func theUnreadableScreenSaysWhatHappenedAndThatNothingChanged() {
        typealias Screen = LaunchpadUnreadableScreen
        #expect(Screen.title(for: .newerFormat) == "This library was made by a newer Agent Tooling")
        #expect(Screen.message(for: .newerFormat) == "Update Agent Tooling on this Mac, then open it again. Nothing was changed.")
        #expect(Screen.title(for: .damaged) == "Agent Tooling could not read this Mac’s library")
        #expect(
            Screen.message(for: .damaged)
                == "Its record, workspace.json, is damaged, so it was left as it is. Nothing was changed.")
        #expect(Screen.title(for: .io("The disk is busy.")) == "Agent Tooling could not read this Mac’s library")
        #expect(Screen.message(for: .io("The disk is busy.")) == "The disk is busy. Nothing was changed.")
        // The record's own reason already says nothing was changed: once.
        let reason = WorkspaceLocatorError.unreadable.localizedDescription
        #expect(reason.hasSuffix("Nothing was changed."))
        let message = Screen.message(for: .io(reason))
        #expect(message.components(separatedBy: "Nothing was changed.").count == 2, "\(message)")
        #expect(message.hasSuffix(" Nothing was changed."))
        #expect(!message.contains("'"), "\(message)")
        #expect(Screen.message(for: .io("This Mac's disk is busy.")) == "This Mac’s disk is busy. Nothing was changed.")
        #expect(Screen.message(for: .io("")) == "Nothing was changed.")
    }

    /// Quit Agent Tooling ↩ for a newer record; Show in Finder beside it for
    /// a damaged one; Try again ↩, with Quit beside it, when the disk would
    /// not read. No later slot and no Back on any of them.
    @Test func theUnreadableScreensButtons() {
        let calls = AppLaunchStateTests.Recorded<String>()
        let actions = LaunchpadUnreadableScreen.Actions(
            quit: { calls.values.append("quit") }, showInFinder: { calls.values.append("finder") },
            tryAgain: { calls.values.append("again") })
        let footers: [(AppLaunchState.UnreadableReason, String, String?)] = [
            (.newerFormat, "Quit Agent Tooling", nil), (.damaged, "Quit Agent Tooling", "Show in Finder"),
            (.io("The disk is busy."), "Try again", "Quit Agent Tooling"),
        ]
        for (reason, primary, secondary) in footers {
            let footer = LaunchpadUnreadableScreen.footer(for: reason, actions: actions)
            #expect(footer.primary?.title == primary)
            #expect(footer.primary?.key == .return)
            #expect(footer.secondary?.title == secondary)
            #expect(footer.showsBack == false)
            guard case .none = footer.later else {
                Issue.record("the unreadable screen offers a later slot for \(reason)")
                continue
            }
            footer.primary?.action()
            footer.secondary?.action()
        }
        #expect(calls.values == ["quit", "quit", "finder", "again", "quit"])
    }

    // MARK: - The window, the menu-bar item and the commands

    @Test func theStagesWindowIsNamedForWhatItDoes() {
        #expect(LaunchpadCopy.Welcome.windowTitle == "Set up Agent Tooling")
    }

    @Test func whileSetupOwnsTheAppTheMenuBarOffersShowSetupAndQuit() {
        #expect(ActionTitles.showSetup == "Show Setup")
        #expect(ActionTitles.quitAgentTooling == "Quit Agent Tooling")
        #expect(ActionTitles.tryAgainMenu == "Try Again")
        #expect(ActionTitles.openAgentTooling == "Open Agent Tooling")
        #expect(ActionTitles.preparingChangesMenu == "Preparing Changes…")
        #expect(LaunchpadCopy.Welcome.couldNotOpenWorkspace == "Agent Tooling could not open your workspace")

        #expect(MenuBarItem.showSetup.title == ActionTitles.showSetup)
        #expect(MenuBarItem.quit.title == ActionTitles.quitAgentTooling)
        // One Quit, word for word, in the menu and on the unreadable screen.
        #expect(LaunchpadCopy.Unreadable.quit == ActionTitles.quitAgentTooling)
        #expect(MenuBarItem.opening.title == LaunchpadCopy.Welcome.openingWorkspace)
        #expect(!MenuBarItem.opening.isEnabled)
        #expect(MenuBarItem.couldNotOpen.title == LaunchpadCopy.Welcome.couldNotOpenWorkspace)
        #expect(MenuBarItem.tryAgain.title == ActionTitles.tryAgainMenu)
        #expect(MenuBarItem.openAgentTooling.title == ActionTitles.openAgentTooling)
        #expect(MenuBarItem.checkApps(checking: false).title == "Check Apps")
        #expect(MenuBarItem.checkApps(checking: true).title == "Checking Apps…")
        #expect(!MenuBarItem.checkApps(checking: true).isEnabled)
        #expect(MenuBarItem.reviewChanges(preparing: false).title == "Review Changes…")
        #expect(MenuBarItem.reviewChanges(preparing: true).title == ActionTitles.preparingChangesMenu)
        #expect(!MenuBarItem.reviewChanges(preparing: true).isEnabled)
        // Show Setup brings a window forward and opens nothing.
        #expect(!ActionTitles.showSetup.hasSuffix("…"))
    }

    @Test func setUpThisMacIsTitleCasedOnlyInMenus() {
        #expect(ActionTitles.setUpThisMacCommand(.menu) == "Set Up This Mac…")
        #expect(ActionTitles.setUpThisMacCommand(.palette) == "Set up this Mac…")
        for title in [ActionTitles.setUpThisMacCommand(.menu), ActionTitles.setUpThisMacCommand(.palette)] {
            #expect(title.hasSuffix("\u{2026}"))
            #expect(!title.hasSuffix("..."))
        }
    }

    @Test func openingWithNoLibrarySaysHowToSetOneUp() {
        #expect(
            WorkspaceLaunch.OpenError.noLibrary.localizedDescription
                == "This Mac has no library to open yet. Quit Agent Tooling and open it again to set one up.")
    }
}

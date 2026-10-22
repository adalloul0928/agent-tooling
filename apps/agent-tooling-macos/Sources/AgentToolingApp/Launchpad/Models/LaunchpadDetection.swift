import AgentToolingCore
import Foundation
import Observation

/// Locates client executables without running them or reading configuration.
/// Only an explicit login-shell lookup runs a command. Newly found tool folders
/// are registered in memory and saved when the library is created. First-run
/// choices remain in memory; rerun toggles save directly to device preferences.
@MainActor @Observable
final class LaunchpadDetection: LaunchpadInterruptible {
    /// One app as detection found it.
    struct App: Equatable, Sendable {
        let client: ClientKind
        /// The tool, where the locator found it; nil when it was not found.
        var executable: URL?

        var isFound: Bool { executable != nil }
    }

    /// Every app, in the app order.
    private(set) var apps: [App]
    /// The apps this Mac will manage, on a first run: the found ones unless
    /// the person changed it.
    private(set) var chosen: Set<ClientKind>
    /// Folders the login shell found a tool in that the locator does not
    /// check on its own. Held until the library is created with them.
    private(set) var toolDirectories: [String]
    /// Every folder the lookups use beyond the fixed ones: those this Mac's
    /// record already holds (a rerun's) and those the login shell found.
    var everyToolDirectory: [String] { Set(recordedToolDirectories).union(toolDirectories).sorted() }
    /// True while the login shell is asked.
    private(set) var isAskingLoginShell = false
    /// What the last ask of the login shell found, in a sentence.
    private(set) var loginShellMessage: String?
    /// This Mac's name, as other Macs see it, once read: the fork line names
    /// it.
    private(set) var deviceName: String?
    /// Whether "Found 3 of 4 apps." has been said, so going Back to the
    /// screen does not say it again.
    var hasAnnounced = false

    @ObservationIgnored private let environment: LaunchpadEnvironment
    /// The folders this Mac's record already holds (a rerun's). Registering
    /// replaces the process's whole list, so these stay in every
    /// registration.
    @ObservationIgnored private let recordedToolDirectories: [String]
    @ObservationIgnored private var lookup: Task<Void, Never>?

    /// How long the login shell has to answer for one app.
    static let loginShellTimeout: Duration = .seconds(10)

    /// Detection over `environment`, looking for every app at once.
    /// `chosen` is a choice already made (going Back to the screen); nil
    /// chooses every app found. `toolDirectories` are folders the login
    /// shell found earlier in this walk.
    init(
        environment: LaunchpadEnvironment, chosen: Set<ClientKind>? = nil, toolDirectories: [String] = [],
        recordedToolDirectories: [String] = []
    ) {
        self.environment = environment
        self.recordedToolDirectories = recordedToolDirectories
        self.toolDirectories = toolDirectories
        let apps = ClientKind.allCases.map { App(client: $0, executable: environment.locate($0, environment.homeURL)) }
        self.apps = apps
        self.chosen = chosen ?? Set(apps.filter(\.isFound).map(\.client))
    }

    /// The detection Your apps draws for `flow`: on a first run, the walk's
    /// choice so far, or every app found; on a rerun, the apps this Mac
    /// manages, with the folders its record holds.
    static func of(_ flow: LaunchpadFlow) -> LaunchpadDetection {
        flow.model(for: .apps) {
            if let workspace = flow.workspace {
                let recorded = workspace.library.state?.snapshot.device.applicationState?.preferences.customToolDirectories ?? []
                return LaunchpadDetection(
                    environment: flow.environment, chosen: Set(workspace.device.managedClients),
                    toolDirectories: flow.seedOverride?.toolDirectories ?? [], recordedToolDirectories: recorded)
            }
            return LaunchpadDetection(
                environment: flow.environment, chosen: flow.seedOverride?.chosen,
                toolDirectories: flow.seedOverride?.toolDirectories ?? [])
        }
    }

    // MARK: What was found

    /// The apps whose tool was found, in the app order.
    var found: [ClientKind] { apps.filter(\.isFound).map(\.client) }
    /// The apps whose tool was not found, in the app order.
    var notFound: [ClientKind] { apps.filter { !$0.isFound }.map(\.client) }
    /// No app's tool was found anywhere looked: V01.
    var isEmptyMac: Bool { found.isEmpty }

    func app(_ client: ClientKind) -> App {
        apps.first { $0.client == client } ?? App(client: client, executable: nil)
    }

    /// Where `client`'s tool was found, as a person reads it, or nil.
    func displayPath(_ client: ClientKind) -> String? {
        app(client).executable.map { PathDisplay.abbreviatingHome($0.path(percentEncoded: false), home: environment.homeURL) }
    }

    // MARK: Choosing

    /// Turns `client` on or off for this Mac, on a first run. An app that
    /// was not found can be turned on too: its read then runs its command
    /// and says what it found.
    func toggle(_ client: ClientKind) {
        if chosen.contains(client) { chosen.remove(client) } else { chosen.insert(client) }
    }

    /// What Continue hands the walk: the apps chosen, the folders the login
    /// shell found, and the projects choice.
    func seed(findsProjectsFromClaudeHistory: Bool) -> LaunchpadSeed {
        LaunchpadSeed(
            chosen: chosen, toolDirectories: toolDirectories, findsProjectsFromClaudeHistory: findsProjectsFromClaudeHistory)
    }

    // MARK: Looking again

    /// ⌘R: looks for every app's tool again, still running nothing. An app
    /// installed since lights in place, and is chosen on a first run unless
    /// it was turned off.
    func lookAgain() {
        let before = Set(found)
        apps = ClientKind.allCases.map { App(client: $0, executable: environment.locate($0, environment.homeURL)) }
        chosen.formUnion(Set(found).subtracting(before))
    }

    /// ⌘L: asks the login shell where the tools still missing live, the way
    /// the person's own terminal would find them. A folder it names that the
    /// locator does not check is held, registered for every lookup in this
    /// process, and recorded when the library is created; then every app is
    /// looked for again.
    func lookAgainWithLoginShell() async {
        guard !isAskingLoginShell else { return }
        let missing = notFound
        guard !missing.isEmpty else { return }
        isAskingLoginShell = true
        loginShellMessage = nil
        let environment = self.environment
        let runner = environment.makeRunner(Self.loginShellTimeout)
        let task = Task { [weak self] in
            let findings = await SmartToolFinder.probe(clients: missing, runner: runner)
            guard let self, !Task.isCancelled else { return }
            self.take(findings, missing: missing)
        }
        lookup = task
        await task.value
        lookup = nil
        isAskingLoginShell = false
    }

    private func take(_ findings: [SmartToolFinder.Finding], missing: [ClientKind]) {
        let home = environment.homeURL
        // Only folders the locator does not already check are worth holding.
        let known = Set(
            findings.flatMap { finding in
                ClientExecutableLocator.candidates(for: finding.client, homeURL: home).map {
                    Self.folderPath($0.deletingLastPathComponent())
                }
            })
        let fresh = Set(findings.map { Self.folderPath($0.directory) }).subtracting(known)
        if !fresh.isEmpty {
            toolDirectories = Set(toolDirectories).union(fresh).sorted()
            environment.registerToolRoots(everyToolDirectory)
        }
        lookAgain()
        let names = ClientKind.allCases.filter(missing.contains).map(\.rawValue)
        let nowFound = ClientKind.allCases.filter { missing.contains($0) && app($0).isFound }.map(\.rawValue)
        loginShellMessage =
            nowFound.isEmpty
            ? LaunchpadCopy.Apps.loginShellFoundNothing(LaunchpadCopy.list(names))
            : LaunchpadCopy.Apps.loginShellFound(LaunchpadCopy.list(nowFound))
    }

    /// A folder as this Mac's record keeps one: absolute, standardized, with
    /// no trailing separator.
    static func folderPath(_ folder: URL) -> String {
        var path = folder.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Reads this Mac's name once, for the fork line.
    func loadDeviceName() async {
        guard deviceName == nil else { return }
        deviceName = await environment.deviceName()
    }

    // MARK: Stopping

    var interruption: LaunchpadInterruption { isAskingLoginShell ? .stoppable : .idle }

    /// Stops asking the login shell; what it had not answered is not kept.
    func interrupt() async {
        lookup?.cancel()
        await lookup?.value
    }

    // MARK: What VoiceOver says

    /// The tile row in one sentence: "Apps: Codex, Claude Code and Gemini
    /// CLI found; Kiro CLI not found".
    var rowSummary: String {
        LaunchpadCopy.Apps.rowSummary(found: found.map(\.rawValue), notFound: notFound.map(\.rawValue))
    }

    /// One tile as a toggle: "Codex, found at /opt/homebrew/bin/codex,
    /// managed".
    func tileLabel(_ client: ClientKind, managed: Bool) -> String {
        LaunchpadCopy.Apps.tileLabel(client.rawValue, foundAt: displayPath(client), managed: managed)
    }

    /// What the tile's key does now: "Command-1 turns it off".
    static func tileHint(_ client: ClientKind, managed: Bool) -> String {
        LaunchpadCopy.Apps.tileHint(key: "Command-\(keyNumber(of: client))", turnsOff: managed)
    }

    /// Said once the stage is drawn: "Found 3 of 4 apps."
    var foundAnnouncement: String {
        LaunchpadCopy.Apps.foundAnnouncement(found.count, of: apps.count)
    }

    /// The digit of `client`'s key: ⌘1 for Codex, ⌘4 for Kiro CLI.
    static func keyNumber(of client: ClientKind) -> Int {
        (ClientKind.allCases.firstIndex(of: client) ?? 0) + 1
    }

    // MARK: Where to look, and where to get an app

    /// The folders the locator checks for `client`'s tool, in the order it
    /// checks them, as one sentence. The four system folders are said once,
    /// and so are mise's and asdf's shims.
    static func lookedIn(for client: ClientKind, homeURL: URL) -> String {
        let system: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let shims: Set<String> = ["~/.local/share/mise/shims", "~/.asdf/shims"]
        var folders: [String] = []
        for candidate in ClientExecutableLocator.candidates(for: client, homeURL: homeURL) {
            let folder = PathDisplay.abbreviatingHome(
                candidate.deletingLastPathComponent().path(percentEncoded: false), home: homeURL)
            let said: String
            if system.contains(folder) {
                said = LaunchpadCopy.Apps.systemFolders
            } else if shims.contains(folder) {
                said = LaunchpadCopy.Apps.shims
            } else {
                said = folder
            }
            if !folders.contains(said) { folders.append(said) }
        }
        return LaunchpadCopy.Apps.lookedIn(folders)
    }

    /// Each app's own install page, checked on 2026-10-19: the page its
    /// vendor keeps for installing the command-line tool on a Mac, at the
    /// address it answers on rather than one that redirects there (Codex's
    /// developers.openai.com page now moves to learn.chatgpt.com).
    static func installPage(for client: ClientKind) -> URL {
        let address =
            switch client {
            case .codex: "https://learn.chatgpt.com/docs/codex/cli"
            case .claude: "https://code.claude.com/docs/en/setup"
            case .gemini: "https://geminicli.com/docs/get-started/installation/"
            case .kiro: "https://kiro.dev/docs/cli/"
            }
        return URL(string: address) ?? URL(filePath: "/")
    }
}

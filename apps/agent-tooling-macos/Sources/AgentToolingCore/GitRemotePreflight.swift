import Foundation

/// Why a repository cannot be joined or connected, in words a person can act
/// on. Each failure has its own cause, so a typo, a sign-in that does not
/// open the repository and a Mac with no network never read alike.
///
/// The two address problems are help for the field, shown before anything
/// runs. Every other description ends with "Nothing was changed.": when one
/// of them is reported, nothing was written to the repository. Git's own
/// message never appears, because it can carry the address, a path or a
/// sign-in prompt.
public enum GitRemoteProblem: Error, Equatable, Sendable, LocalizedError {
    /// The address cannot be used as typed. `suggestion` is the HTTPS form
    /// of it, when one can be worked out (`GitRemoteAddress.httpsSuggestion`).
    /// `carriesSignIn` is true when the address names a user or a password,
    /// as `git@github.com:you/library.git` does, or carries anything after
    /// its path, where a token hides: that is then why it is refused.
    /// Otherwise it is refused for its form, as an `http://` address or one
    /// with no scheme is.
    case invalidAddress(suggestion: String?, carriesSignIn: Bool)
    /// The branch name is not one Git accepts.
    case invalidBranch
    /// Git cannot run on this Mac: Apple's Command Line Tools are missing.
    case gitMissing
    /// The host could not be reached: no network, a name that does not
    /// resolve, a connection refused. `host` is nil for a folder on this Mac.
    case unreachable(host: String?)
    /// Git could not sign in to the host with what this Mac has stored.
    case signInFailed(host: String?)
    /// Nothing answered at that address that this Mac can see: a typo, or a
    /// private repository this Mac's sign-in does not open. Hosts report the
    /// two the same way.
    case notFound(host: String?)
    /// The host took longer to answer than Agent Tooling waits.
    case timedOut(host: String?)
    /// The repository holds nothing at all yet: no branch of any name.
    case emptyRemote
    /// The repository has branches, but none by this name: a typo in the
    /// branch, most likely. Only a join reports it; for a connect, a branch
    /// not there yet is where this Mac's library goes.
    case noSuchBranch(String)
    /// The repository holds files, but no library.
    case notALibrary
    /// The repository's library was made by a newer Agent Tooling.
    case newerFormat
    /// The repository holds a library this build should read, and it could
    /// not be read.
    case unreadable
    /// The repository holds a different library from the one this Mac has.
    case differentLibrary
    /// The host did not take what this Mac published. A preflight never
    /// reports this one; a publish does.
    case pushRefused(host: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress, .invalidBranch: sentence
        default: sentence + " Nothing was changed."
        }
    }

    /// The description without its closing "Nothing was changed.", for a
    /// caller that adds that clause itself.
    var sentence: String {
        switch self {
        case .invalidAddress(_, let carriesSignIn):
            carriesSignIn
                ? "Enter a repository address without a user name or password in it."
                : "Enter a repository address that starts with https://."
        case .invalidBranch:
            "Enter a branch name with no spaces, such as main."
        case .gitMissing:
            "Git is not installed on this Mac. Install Apple’s Command Line Tools, then try again."
        case .unreachable(let host):
            "Git could not reach \(host ?? "that repository") from this Mac. Check the network connection, then try again."
        case .signInFailed(let host):
            "Git could not sign in to \(host ?? "that repository") from this Mac."
        case .notFound(let host):
            if let host {
                "\(host) has no repository at this address that this Mac can see. Check the spelling, or your Git sign-in for \(host)."
            } else {
                "There is no repository at that address on this Mac. Check the spelling."
            }
        case .timedOut(let host):
            "\(host ?? "That repository") did not answer in time. Try again in a moment."
        case .emptyRemote:
            "That repository holds no workspace yet. Connect the Mac that has your library first, so it publishes one."
        case .noSuchBranch(let branch):
            "That repository has no branch called “\(branch)”. Check the branch name."
        case .notALibrary:
            "That repository holds other files, not an Agent Tooling library. Check the address, or use an empty private repository."
        case .newerFormat:
            "This library needs a newer Agent Tooling. Update this Mac first."
        case .unreadable:
            "That repository holds a library this Mac could not read. Its workspace.json may be damaged."
        case .differentLibrary:
            "That repository holds a different library. Use an empty private repository for this Mac’s library."
        case .pushRefused(let host):
            "\(host ?? "That repository") did not accept what this Mac published. Check that your Git sign-in can write to it."
        }
    }

    /// The preflight check this problem stops at: the row J01 marks as failed.
    /// `nil` for the address field's own problems, which stop the preflight
    /// before any check runs, and for a refused publish, which no preflight
    /// reports.
    public var failedCheck: GitRemotePreflight.Check? {
        switch self {
        case .invalidAddress, .invalidBranch, .pushRefused: nil
        case .gitMissing: .gitInstalled
        case .unreachable, .signInFailed, .notFound, .timedOut: .reachable
        case .emptyRemote, .noSuchBranch, .notALibrary, .differentLibrary: .holdsLibrary
        case .newerFormat, .unreadable: .readable
        }
    }
}

/// What a repository holds, as the preflight read it.
public struct GitRemotePreflightResult: Equatable, Sendable {
    /// The branch's head commit, or `nil` when the branch holds nothing yet.
    public let head: String?
    /// The library's workspace, or `nil` when the branch holds nothing yet.
    public let workspaceID: WorkspaceObjectID?
    /// How many tools the library holds, counted the way Library counts them,
    /// without Agent Tooling's own connection, which is bound to each Mac
    /// rather than a tool of the library (`AgentToolingConnection`).
    public let toolCount: Int
    /// The other Macs that use the library, in the order they joined it.
    /// Retired Macs and this one are left out.
    public let deviceNames: [String]
    /// The name this Mac would register under: the one asked for, numbered
    /// when another Mac already uses it ("Cedar 2").
    public let suggestedName: String
    /// What each Mac in `deviceNames` last published about itself. A retired
    /// Mac's last status stays in the repository and is left out here.
    public let statuses: [PublishedDeviceStatus]

    public init(
        head: String?, workspaceID: WorkspaceObjectID?, toolCount: Int, deviceNames: [String], suggestedName: String,
        statuses: [PublishedDeviceStatus]
    ) {
        self.head = head
        self.workspaceID = workspaceID
        self.toolCount = toolCount
        self.deviceNames = deviceNames
        self.suggestedName = suggestedName
        self.statuses = statuses
    }
}

/// Validates a remote using only its contents and a temporary scratch folder.
/// Checks Command Line Tools before Git to avoid launching the macOS installer,
/// then checks reachability, shallow-fetches the branch and validates its schema.
/// A newer schema is distinguished from a damaged document.
public enum GitRemotePreflight {
    /// One check, in the order J01 lists them.
    public enum Check: Int, CaseIterable, Sendable {
        /// "Git is installed".
        case gitInstalled = 1
        /// "github.com answered".
        case reachable
        /// "It holds a library".
        case holdsLibrary
        /// "This build can read it".
        case readable
    }

    /// Where a check is. Each one is reported started, then passed or failed.
    /// A cancelled preflight reports nothing more.
    public enum CheckState: Equatable, Sendable {
        case started
        case passed
        case failed
    }

    static let developerToolsLocator = "/usr/bin/xcode-select"

    /// Checks a join when `expectingWorkspace` is nil: the branch must hold a library.
    /// For connect, a missing branch or matching workspace is allowed; another
    /// library is rejected. Excludes `thisDevice` from name conflicts. Each run
    /// trims the remote, uses a fresh scratch folder and removes it on return.
    /// Cancellation takes effect at the next command.
    public static func run(
        remote: String,
        branch: String = "main",
        deviceName: String,
        expectingWorkspace: WorkspaceObjectID? = nil,
        thisDevice: WorkspaceObjectID? = nil,
        runner: any CommandRunning,
        scratch: URL,
        progress: @Sendable (Check, CheckState) -> Void = { _, _ in }
    ) async throws(CancellationError) -> Result<GitRemotePreflightResult, GitRemoteProblem> {
        let remote = GitRemoteAddress.trimmed(remote)
        if let problem = GitRemoteAddress.problem(remote) { return .failure(problem) }
        guard GitWorkspaceTransport.isValidBranch(branch) else { return .failure(.invalidBranch) }
        let host = GitRemoteAddress.host(of: remote)
        let folder = scratch.standardizedFileURL.appending(
            path: "preflight-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }

        var check = Check.gitInstalled
        do {
            progress(.gitInstalled, .started)
            try await requireGit(runner: runner)
            progress(.gitInstalled, .passed)

            check = .reachable
            progress(.reachable, .started)
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw GitRemoteProblem.notFound(host: host)
            }
            let transport = try GitWorkspaceTransport(checkout: folder, branch: branch, runner: runner)
            try await transport.git(["init", "--quiet"])
            let advertised = try await transport.advertisedHead(of: remote, host: host)
            progress(.reachable, .passed)

            check = .holdsLibrary
            progress(.holdsLibrary, .started)
            let name = WorkspaceJoin.requestedName(deviceName)
            guard advertised != nil, let head = try await transport.shallowFetch(from: remote, host: host) else {
                guard expectingWorkspace != nil else {
                    // Nothing to join on this branch: a typo in its name,
                    // unless the repository has no branch at all.
                    let hasBranches = try await transport.listsAnyBranch(on: remote, host: host)
                    throw hasBranches ? GitRemoteProblem.noSuchBranch(branch) : GitRemoteProblem.emptyRemote
                }
                // Nothing there yet is where this Mac's library will go.
                progress(.holdsLibrary, .passed)
                progress(.readable, .started)
                progress(.readable, .passed)
                return .success(
                    .init(head: nil, workspaceID: nil, toolCount: 0, deviceNames: [], suggestedName: name, statuses: []))
            }
            guard let text = try await transport.documentText(at: head) else { throw GitRemoteProblem.notALibrary }
            let bytes = Data(text.utf8)
            let library = RemoteDocumentFormat.classify(bytes)
            switch library {
            case .notALibrary:
                throw GitRemoteProblem.notALibrary
            case .library(let format):
                if let expectingWorkspace, format.workspaceID != expectingWorkspace {
                    throw GitRemoteProblem.differentLibrary
                }
            case .damaged:
                break
            }
            progress(.holdsLibrary, .passed)

            check = .readable
            progress(.readable, .started)
            guard case .library(let format) = library else { throw GitRemoteProblem.unreadable }
            guard !format.isNewer else { throw GitRemoteProblem.newerFormat }
            let document: PortableWorkspaceDocument
            let toolCount: Int
            do {
                document = try WorkspaceDocumentCoding.decode(bytes)
                toolCount = try libraryToolCount(document)
            } catch {
                throw GitRemoteProblem.unreadable
            }
            let statuses = (try? await transport.deviceStatuses(at: head)) ?? []
            try Task.checkCancellation()
            let living = document.deviceRegistry.filter { !$0.isRetired && $0.id != thisDevice }
                .sorted { ($0.registeredAt, $0.name) < ($1.registeredAt, $1.name) }
            let livingIDs = Set(living.map(\.id))
            progress(.readable, .passed)
            return .success(
                .init(
                    head: head, workspaceID: document.workspaceID, toolCount: toolCount,
                    deviceNames: living.map(\.name),
                    suggestedName: WorkspaceJoin.uniqueName(name, among: living),
                    statuses: statuses.filter { livingIDs.contains($0.deviceID) }))
        } catch let problem as GitRemoteProblem {
            return .failure(report(problem, from: check, progress: progress))
        } catch GitWorkspaceTransportError.remote(let problem) {
            return .failure(report(problem, from: check, progress: progress))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A local failure partway, such as a scratch folder that could
            // not be written: reported at the check it stopped, in that
            // check's own terms.
            return .failure(report(fallback(at: check, host: host), from: check, progress: progress))
        }
    }

    /// Reports `problem` as the one failed check of this run. It fails at its
    /// own check (`failedCheck`) when that comes later than the one running,
    /// the checks between passing first, and at the running one otherwise, so
    /// a run always reads as passes, then one failure, in order.
    private static func report(
        _ problem: GitRemoteProblem, from running: Check, progress: (Check, CheckState) -> Void
    ) -> GitRemoteProblem {
        var check = running
        while let own = problem.failedCheck, own.rawValue > check.rawValue, let next = Check(rawValue: check.rawValue + 1) {
            progress(check, .passed)
            check = next
            progress(check, .started)
        }
        progress(check, .failed)
        return problem
    }

    /// The tools a published library holds, as Library counts them, less
    /// Agent Tooling's own connection: J01's "It holds a library (13 tools)".
    /// The helper is bound to each Mac, not a tool the library carries.
    static func libraryToolCount(_ document: PortableWorkspaceDocument) throws -> Int {
        let model = try WorkspaceLibraryReadModel(
            snapshot: .init(document: document, device: DeviceWorkspaceState(workspaceID: document.workspaceID)))
        let definitions = document.mcpDefinitions ?? []
        let own = Set(
            document.artifacts.filter { AgentToolingConnection.isOwnConnection($0, definitions: definitions) }.map(\.identity.id))
        return model.rows.filter { !own.contains($0.artifactID) }.count + model.nestedToolCount
    }

    /// `xcode-select -p` first: when it has no developer folder to name,
    /// `/usr/bin/git` would open the Command Line Tools installer.
    private static func requireGit(runner: any CommandRunning) async throws {
        let located: CommandOutput
        let version: CommandOutput
        do {
            located = try await runner.run(executable: developerToolsLocator, arguments: ["-p"], currentDirectory: nil)
            try Task.checkCancellation()
            guard located.status == 0, !located.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw GitRemoteProblem.gitMissing }
            version = try await runner.run(executable: GitWorkspaceTransport.gitExecutable, arguments: ["--version"], currentDirectory: nil)
            try Task.checkCancellation()
        } catch let problem as GitRemoteProblem {
            throw problem
        } catch {
            try Task.checkCancellation()
            throw GitRemoteProblem.gitMissing
        }
        guard version.status == 0, version.standardOutput.hasPrefix("git version") else { throw GitRemoteProblem.gitMissing }
    }

    private static func fallback(at check: Check, host: String?) -> GitRemoteProblem {
        switch check {
        case .gitInstalled: .gitMissing
        case .reachable: .notFound(host: host)
        case .holdsLibrary, .readable: .unreadable
        }
    }
}

/// The two numbers and the identity a library's `workspace.json` carries in
/// every format, read before the document itself so a newer format is told
/// apart from a damaged one.
struct RemoteDocumentFormat: Decodable {
    let schemaVersion: UInt
    let minimumReaderVersion: UInt?
    let workspaceID: WorkspaceObjectID

    /// What a file called `workspace.json` turned out to be.
    enum Reading {
        /// A library, in this format.
        case library(RemoteDocumentFormat)
        /// Not JSON at all: taken for a library whose file was damaged.
        case damaged
        /// JSON that carries none of this: some other file of that name.
        case notALibrary
    }

    /// Whether this build is too old to read it.
    var isNewer: Bool {
        let current = PortableWorkspaceDocument.currentSchemaVersion
        return schemaVersion > current || (minimumReaderVersion ?? schemaVersion) > current
    }

    static func classify(_ bytes: Data) -> Reading {
        if let format = try? JSONDecoder().decode(Self.self, from: bytes) { return .library(format) }
        return (try? JSONSerialization.jsonObject(with: bytes)) == nil ? .damaged : .notALibrary
    }
}

/// What Git's standard error says went wrong talking to a remote. Apple's Git
/// ships without translations, so its messages are English whatever the
/// language is; a message nothing here recognises is left for the caller to
/// decide.
enum GitRemoteFailure {
    /// The branch asked for is not on the remote. An empty repository answers
    /// a fetch this way, and so does one that only has other branches.
    static func isMissingRemoteBranch(_ standardError: String) -> Bool {
        standardError.lowercased().contains("couldn't find remote ref")
    }

    /// A push refused because the remote moved since this Mac read it.
    static func isRejectedBecauseRemoteMoved(_ standardError: String) -> Bool {
        let text = standardError.lowercased()
        return text.contains("[rejected]") && (text.contains("fetch first") || text.contains("non-fast-forward"))
    }

    /// The problem the message describes, or `nil` when nothing in it is
    /// recognised. `pushing` reads a refusal to accept the push as such,
    /// rather than as a sign-in that does not open the repository.
    static func problem(standardError: String, host: String?, pushing: Bool = false) -> GitRemoteProblem? {
        let text = standardError.lowercased()
        func mentions(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }
        if mentions(["xcrun: error", "invalid active developer path", "no developer tools were found"]) {
            return .gitMissing
        }
        if mentions(signInPhrases) { return .signInFailed(host: host) }
        if pushing, mentions(refusedPushPhrases) { return .pushRefused(host: host) }
        if mentions(["permission to ", "returned error: 403", "access denied", "permission denied"]) {
            return host == nil ? .notFound(host: nil) : .signInFailed(host: host)
        }
        if mentions(["repository not found", "does not appear to be a git repository", "returned error: 404", "not found"]) {
            return .notFound(host: host)
        }
        if mentions(["timed out", "timeout"]) { return .timedOut(host: host) }
        if mentions(networkPhrases) { return .unreachable(host: host) }
        return nil
    }

    private static let signInPhrases = [
        "returned error: 401", "authentication failed", "could not read username", "could not read password",
        "terminal prompts disabled", "invalid username or password", "permission denied (publickey",
        "password authentication is not supported", "support for password authentication was removed",
    ]

    private static let refusedPushPhrases = [
        "[remote rejected]", "permission to ", "returned error: 403", "write access to repository not granted",
        "protected branch", "hook declined", "denied",
    ]

    private static let networkPhrases = [
        "could not resolve host", "couldn't resolve host", "could not resolve proxy", "failed to connect",
        "couldn't connect to server", "connection refused", "network is unreachable", "no route to host",
        "connection reset", "ssl", "tls", "proxy", "returned error: 5", "the remote end hung up", "early eof",
    ]
}

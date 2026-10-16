import Foundation

/// Pure readings of Codex app-server answers, each pinned by a fixture.
enum CodexAccountParsing {
    /// `initialize` returns a user agent such as
    /// `agent-tooling/0.162.1 (Mac OS 26.7.1; arm64) …`; the version is the
    /// token after the first slash.
    static func version(fromInitialize result: JSONValue) -> String? {
        guard let agent = result["userAgent"]?.stringValue, let slash = agent.firstIndex(of: "/") else { return nil }
        let token = agent[agent.index(after: slash)...].prefix { !$0.isWhitespace }
        return token.first?.isNumber == true ? String(token.prefix(64)) : nil
    }

    /// `account/read`: `{ account: null | {type, email?, planType?,
    /// credentialSource?}, requiresOpenaiAuth }`.
    static func signIn(fromAccountRead result: JSONValue) -> AccountSignIn? {
        guard result.objectValue != nil else { return nil }
        let requiresOpenAIAuth = result["requiresOpenaiAuth"]?.boolValue ?? true
        guard let account = result["account"], !account.isNull else {
            // No account and no need for one is a provider of its own, such
            // as a local model; no account and a need for one is signed out.
            return AccountSignIn(method: requiresOpenAIAuth ? .signedOut : .thirdParty)
        }
        let type = account["type"]?.stringValue ?? ""
        switch type {
        case "chatgpt":
            return AccountSignIn(
                method: .subscription, email: ClaudeAccountParsing.bounded(account["email"]?.stringValue),
                plan: ClaudeAccountParsing.bounded(account["planType"]?.stringValue))
        case "apiKey":
            return AccountSignIn(method: .apiKey)
        case "amazonBedrock":
            return AccountSignIn(method: .thirdParty, provider: "amazonBedrock")
        default:
            return AccountSignIn(method: type.isEmpty ? .unknown : .thirdParty, provider: ClaudeAccountParsing.bounded(type))
        }
    }

    /// One page of `app/list`.
    struct AppListPage: Hashable, Sendable {
        var apps: [CodexApp]
        var nextCursor: String?
    }

    struct CodexApp: Hashable, Sendable {
        var id: String
        var name: String
        var summary: String?
        var installURL: URL?
        /// Connected to the ChatGPT account.
        var isAccessible: Bool
        /// What `config.toml` says, as app-server reports it.
        var isEnabled: Bool
    }

    /// The requested page size for `app/list`, and the matching cap on how
    /// many rows are parsed from one page so the parser never keeps more than
    /// was asked for.
    static let appListPageLimit = 100

    static func appList(_ result: JSONValue, limit: Int = appListPageLimit) -> AppListPage? {
        guard let rows = result["data"]?.arrayValue else { return nil }
        let apps = rows.prefix(limit).compactMap { row -> CodexApp? in
            guard let id = row["id"]?.stringValue, !id.isEmpty, id.count <= 256 else { return nil }
            let name = ClaudeAccountParsing.bounded(row["name"]?.stringValue) ?? id
            let url = row["installUrl"]?.stringValue.flatMap(URL.init(string:)).flatMap { url in
                url.scheme?.lowercased() == "https" ? url : nil
            }
            let summary = ClaudeAccountParsing.bounded(row["description"]?.stringValue, maximum: 2_000).map { String($0.prefix(240)) }
            return CodexApp(
                id: id, name: name, summary: summary, installURL: url,
                isAccessible: row["isAccessible"]?.boolValue ?? false, isEnabled: row["isEnabled"]?.boolValue ?? true)
        }
        return AppListPage(apps: apps, nextCursor: result["nextCursor"]?.stringValue)
    }

    struct InstalledApp: Hashable, Sendable {
        var id: String
        var enabled: Bool
        var callable: Bool
    }

    /// `app/installed`: the effective runtime state of each app.
    static func installedApps(_ result: JSONValue) -> [String: InstalledApp] {
        var apps: [String: InstalledApp] = [:]
        for row in (result["apps"]?.arrayValue ?? []).prefix(1_000) {
            guard let id = row["id"]?.stringValue, !id.isEmpty else { continue }
            apps[id] = InstalledApp(id: id, enabled: row["enabled"]?.boolValue ?? false, callable: row["callable"]?.boolValue ?? false)
        }
        return apps
    }

    /// The account switches one Codex configuration object holds: the
    /// `[features] apps` flag and the `[apps]` tables.
    static func switches(fromConfig config: JSONValue?) -> [AccountPreferenceKey: AccountPreferenceValue] {
        var switches: [AccountPreferenceKey: AccountPreferenceValue] = [:]
        guard let config else { return switches }
        if let flag = config["features"]?["apps"]?.boolValue {
            switches[.init(.apps)] = flag ? .on : .off
        }
        for (id, table) in config["apps"]?.objectValue ?? [:] {
            let subject: String?
            if id == "_default" {
                subject = nil
            } else if AccountPreferences.isValidAppID(id) {
                subject = id
                if let flag = table["enabled"]?.boolValue { switches[.init(.app, subject: id)] = flag ? .on : .off }
            } else {
                continue
            }
            if let flag = table["destructive_enabled"]?.boolValue {
                switches[.init(.destructiveTools, subject: subject)] = flag ? .on : .off
            }
            if let flag = table["open_world_enabled"]?.boolValue {
                switches[.init(.openWorldTools, subject: subject)] = flag ? .on : .off
            }
            if let mode = table["default_tools_approval_mode"]?.stringValue,
               let value = AccountPreferenceValue(rawValue: mode),
               AccountSetting.approvalMode.acceptedValues.contains(value) {
                switches[.init(.approvalMode, subject: subject)] = value
            }
        }
        return switches
    }

    /// `config/read` with `includeLayers`: the effective configuration and
    /// the user layer, with the file the user layer came from.
    struct ConfigReading: Sendable {
        var effective: JSONValue?
        var user: JSONValue?
        var userFile: String?
    }

    static func configReading(_ result: JSONValue) -> ConfigReading {
        let user = result["layers"]?.arrayValue?.first { $0["name"]?["type"]?.stringValue == "user" }
        return ConfigReading(
            effective: result["config"], user: user?["config"], userFile: user?["name"]?["file"]?.stringValue)
    }
}

/// Reads what the ChatGPT account puts in front of Codex on this Mac.
///
/// It speaks to `codex app-server` through a session that can only read, and
/// asks for nothing that needs the network unless the full contents were
/// requested. ChatGPT's remote plugins are not read: Codex documents
/// `plugin/list` as under development and not for production clients.
public struct CodexAccountReader: Sendable {
    public typealias SessionFactory = @Sendable (URL, URL) throws -> CodexAppServerSession

    private let homeURL: URL
    private let locate: @Sendable (ClientKind, URL) -> URL?
    private let makeSession: SessionFactory
    private let clientVersion: String

    public init(
        homeURL: URL,
        locate: @escaping @Sendable (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) },
        clientVersion: String = "1",
        makeSession: @escaping SessionFactory = { executable, home in
            try CodexAppServerSession.launch(executable: executable, homeURL: home)
        }
    ) {
        self.homeURL = homeURL
        self.locate = locate
        self.clientVersion = clientVersion
        self.makeSession = makeSession
    }

    public func read(contents: Bool, shellOverrides: [AccountShellOverride] = [], now: Date = .now) async -> AccountObservation {
        let provider = AccountProvider.chatGPT
        let overrides = shellOverrides.filter { $0.provider == provider }
        var observation = AccountObservation(provider: provider, observedAt: now, contentsRead: contents, shellOverrides: overrides)
        guard let executable = locate(.codex, homeURL) else {
            observation.contentsRead = false
            observation.unavailableReason = "Codex's command-line tool was not found on this Mac, so its ChatGPT account could not be read."
            return observation
        }
        let session: CodexAppServerSession
        do {
            session = try makeSession(executable, homeURL)
        } catch {
            observation.contentsRead = false
            observation.unavailableReason = SensitiveValueRedactor.redact(error.localizedDescription)
            return observation
        }
        do {
            let hello = try await session.initialize(clientName: "agent_tooling", clientTitle: "Agent Tooling", version: clientVersion)
            observation.clientVersion = CodexAccountParsing.version(fromInitialize: hello)
            observation.signIn = CodexAccountParsing.signIn(
                fromAccountRead: try await session.request("account/read", params: .object(["refreshToken": .bool(false)])))
            let reading = CodexAccountParsing.configReading(
                try await session.request("config/read", params: .object(["includeLayers": .bool(true)])))
            applySwitches(reading, to: &observation)

            if contents {
                if observation.reachesAccount {
                    try await readApps(session: session, into: &observation)
                } else {
                    observation.notes.append(
                        "ChatGPT apps reach Codex only when it signs in with ChatGPT. On this Mac it uses \(observation.signIn?.summary(for: provider) ?? "an unknown sign-in").")
                }
            }
        } catch {
            let detail = SensitiveValueRedactor.redact(error.localizedDescription)
            if observation.signIn == nil {
                observation.contentsRead = false
                observation.unavailableReason = detail
            } else {
                observation.notes.append(detail)
            }
        }
        await session.close()
        if observation.switches[.init(.apps)] == .off {
            observation.notes.append("Apps are turned off in Codex on this Mac ([features] apps = false).")
        }
        observation.notes.append("Remote plugins from the ChatGPT plugin directory are not listed: Codex does not yet offer a stable way to read them.")
        return observation
    }

    private func applySwitches(_ reading: CodexAccountParsing.ConfigReading, to observation: inout AccountObservation) {
        let user = CodexAccountParsing.switches(fromConfig: reading.user)
        let effective = CodexAccountParsing.switches(fromConfig: reading.effective)
        observation.fileValues = user
        observation.switches = effective.merging(user) { effectiveValue, _ in effectiveValue }
        // A value the user file sets that the effective configuration does not
        // carry is overridden by something above the file.
        for (key, value) in user where effective[key] != nil && effective[key] != value {
            observation.constrained[key] = "Set by a configuration layer that takes precedence over ~/.codex/config.toml"
        }
        let expected = ClientConfigurationFile.codexConfig.url(homeURL: homeURL).standardizedFileURL.path(percentEncoded: false)
        if let file = reading.userFile,
           URL(filePath: file).standardizedFileURL.path(percentEncoded: false) != expected,
           URL(filePath: file).resolvingSymlinksInPath().path(percentEncoded: false)
               != URL(filePath: expected).resolvingSymlinksInPath().path(percentEncoded: false) {
            observation.writeBlocker = "Codex on this Mac reads its configuration from \(file), and this app only edits ~/.codex/config.toml."
        }
    }

    private func readApps(session: CodexAppServerSession, into observation: inout AccountObservation) async throws {
        var apps: [CodexAccountParsing.CodexApp] = []
        var cursor: JSONValue = .null
        // A person's account holds a few dozen apps; this ceiling is far above
        // any real directory while still bounding a server that answers with
        // large pages, so the kept set never grows to the 10×page product.
        let maximumKept = 1_000
        let pageLimit = CodexAccountParsing.appListPageLimit
        for _ in 0..<10 {
            let page = try await session.request(
                "app/list", params: .object(["cursor": cursor, "limit": .number(Double(pageLimit)), "forceRefetch": .bool(false)]),
                timeout: .seconds(60))
            guard let parsed = CodexAccountParsing.appList(page, limit: pageLimit) else {
                throw CodexAppServerError.malformedResponse("app/list")
            }
            apps += parsed.apps
            guard apps.count < maximumKept else {
                apps = Array(apps.prefix(maximumKept))
                break
            }
            guard let next = parsed.nextCursor, !next.isEmpty else { break }
            cursor = .string(next)
        }
        let installed = (try? await session.request("app/installed", params: .object(["forceRefresh": .bool(false)])))
            .map(CodexAccountParsing.installedApps) ?? [:]

        var seen = Set<String>()
        let accessible = apps.filter { $0.isAccessible && seen.insert($0.id).inserted }
        observation.directoryCount = Set(apps.filter { !$0.isAccessible }.map(\.id)).subtracting(seen).count
        observation.items = accessible.map { app in
            let key = AccountPreferenceKey(.app, subject: app.id)
            let state: AccountItemState
            let detail: String?
            if let runtime = installed[app.id] {
                if runtime.callable {
                    state = .init(tone: .ready, label: "Ready in Codex")
                    detail = app.summary
                } else if runtime.enabled {
                    state = .init(tone: .attention, label: "Enabled, not callable")
                    detail = "Codex sees the app, but none of its tools passes the app and tool policies."
                } else {
                    state = .init(tone: .off, label: "Off in Codex")
                    detail = observation.fileValues[key] == .off
                        ? "Codex's config.toml turns it off on this Mac."
                        : "A policy or configuration layer turns it off."
                }
            } else {
                state = app.isEnabled
                    ? .init(tone: .neutral, label: "Not loaded yet")
                    : .init(tone: .off, label: "Off in Codex")
                detail = app.summary
            }
            // Runtime state is shown, not folded into the switch: an app a
            // workspace policy blocks is off whatever config.toml says, and
            // writing the file again would not change that.
            if let runtime = installed[app.id], !runtime.enabled, observation.switches[key] != .off {
                observation.constrained[key] = "Turned off by your ChatGPT workspace or a Codex policy"
            }
            return AccountItem(
                provider: .chatGPT, kind: .app, key: app.id, name: app.name, detail: detail, state: state,
                setting: AccountPreferences.isValidAppID(app.id) ? .app : nil,
                url: app.installURL ?? URL(string: "https://chatgpt.com/apps"), facts: [])
        }
    }
}

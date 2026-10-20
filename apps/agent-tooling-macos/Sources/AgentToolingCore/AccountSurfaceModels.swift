import CryptoKit
import Foundation

// MARK: - Providers

/// The two hosted accounts whose contents reach this Mac's coding clients.
///
/// A claude.ai account's connectors, skills and plugins reach Claude Code when
/// it signs in with that account, and a ChatGPT account's apps reach Codex the
/// same way. Neither account is this Mac's: each syncs itself to every place it
/// signs in, so this app reads it from whichever Mac it runs on and never
/// copies its contents into the portable document.
public enum AccountProvider: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case claude
    case chatGPT = "chatgpt"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    /// The account's own name, as its vendor spells it.
    public var accountName: String {
        switch self {
        case .claude: "claude.ai"
        case .chatGPT: "ChatGPT"
        }
    }

    /// The local client that reads this account on a Mac.
    public var client: ClientKind {
        switch self {
        case .claude: .claude
        case .chatGPT: .codex
        }
    }

    public var surface: TargetSurface {
        client.defaultSurface
    }

    /// Where the account's contents are added, connected and removed.
    public var manageURL: URL {
        let address =
            switch self {
            case .claude: "https://claude.ai/customize"
            case .chatGPT: "https://chatgpt.com/apps"
            }
        guard let url = URL(string: address) else {
            preconditionFailure("The built-in account management URL must be valid.")
        }
        return url
    }

    /// The page that manages one kind of item, falling back to the account's
    /// customization page.
    public func manageURL(for kind: AccountItemKind?) -> URL {
        switch (self, kind) {
        case (.claude, .connector?): manageURL.appending(path: "connectors")
        case (.claude, .skill?): manageURL.appending(path: "skills")
        case (.claude, .plugin?): manageURL.appending(path: "plugins")
        default: manageURL
        }
    }

    /// Declaration order: Claude, then ChatGPT, on every screen and in every
    /// saved record.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    public static func provider(for client: ClientKind) -> AccountProvider? {
        allCases.first { $0.client == client }
    }
}

// MARK: - Sign-in

/// How a client on this Mac is signed in, as the client itself reports it.
///
/// Only a subscription sign-in lets the account's contents reach the client:
/// Claude Code fetches claude.ai connectors, skills and plugins only for a
/// claude.ai login, and Codex lists ChatGPT apps only for a ChatGPT login.
public struct AccountSignIn: Codable, Hashable, Sendable {
    public enum Method: String, Codable, CaseIterable, Sendable {
        /// Signed in with the claude.ai or ChatGPT subscription.
        case subscription
        /// An API key (`ANTHROPIC_API_KEY`, `/login` console key, OpenAI key).
        case apiKey
        /// A long-lived token such as `CLAUDE_CODE_OAUTH_TOKEN`, which makes
        /// model requests only.
        case token
        /// A key helper script supplies the credential.
        case keyHelper
        /// A third-party provider: Bedrock, Google Cloud, a gateway.
        case thirdParty
        case signedOut
        case unknown

        public var reachesAccount: Bool { self == .subscription }
    }

    public var method: Method
    /// The third-party provider or credential source the client named.
    public var provider: String?
    /// Kept on this Mac only. What is published to other Macs is a
    /// fingerprint, never the address.
    public var email: String?
    public var organizationID: String?
    public var organizationName: String?
    /// The plan the client reported: `pro`, `max`, `team`, `plus`, and so on.
    public var plan: String?
    /// Claude Code's configuration directory, when it reported one.
    public var configDirectory: String?

    public init(
        method: Method, provider: String? = nil, email: String? = nil, organizationID: String? = nil,
        organizationName: String? = nil, plan: String? = nil, configDirectory: String? = nil
    ) {
        self.method = method
        self.provider = provider
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.plan = plan
        self.configDirectory = configDirectory
    }

    /// One line, for a row: "claude.ai · Max · Acme". The address is left to
    /// the screen, which decides whether to show it.
    public func summary(for provider: AccountProvider) -> String {
        switch method {
        case .subscription:
            let parts = [provider.accountName, plan.map(Self.planLabel), organizationName].compactMap { $0 }
            return parts.joined(separator: " · ")
        case .apiKey: return "an API key"
        case .token: return "a long-lived token"
        case .keyHelper: return "a key helper script"
        case .thirdParty: return self.provider.map(Self.providerLabel) ?? "a third-party provider"
        case .signedOut: return "not signed in"
        case .unknown: return "an unrecognised sign-in"
        }
    }

    static func planLabel(_ plan: String) -> String {
        plan.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func providerLabel(_ provider: String) -> String {
        switch provider.lowercased() {
        case "bedrock": "Bedrock"
        case "vertex", "vertexai", "agentplatform": "Google Cloud"
        case "foundry", "azure": "Microsoft Foundry"
        default: provider
        }
    }
}

// MARK: - What an account holds

public enum AccountItemKind: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case connector
    case skill
    case plugin
    case app

    public var id: String { rawValue }

    public var pluralName: String {
        switch self {
        case .connector: "Connectors"
        case .skill: "Skills"
        case .plugin: "Plugins"
        case .app: "Apps"
        }
    }

    public var singularName: String {
        switch self {
        case .connector: "connector"
        case .skill: "skill"
        case .plugin: "plugin"
        case .app: "app"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// What the client said about one account item, in words a row can show.
public struct AccountItemState: Hashable, Sendable {
    public enum Tone: String, Hashable, Sendable {
        /// Loading or connected; nothing to do.
        case ready
        /// Something a person should look at.
        case attention
        /// Turned off on this Mac.
        case off
        /// Nothing settled either way.
        case neutral
    }

    public var tone: Tone
    public var label: String

    public init(tone: Tone, label: String) {
        self.tone = tone
        self.label = label
    }

    public var healthState: HealthState {
        switch tone {
        case .ready: .healthy
        case .attention: .attention
        case .off, .neutral: .pending
        }
    }
}

/// One thing a hosted account holds, as this Mac's client sees it.
public struct AccountItem: Identifiable, Hashable, Sendable {
    public var provider: AccountProvider
    public var kind: AccountItemKind
    /// The identifier a local switch names: a plugin's name, a connector's
    /// display name, an app's id, a skill's folder.
    public var key: String
    public var name: String
    public var detail: String?
    public var state: AccountItemState
    /// The account-wide switch that turns this item off on a Mac, when it has
    /// one. Skills have none: claude.ai turns each one on or off itself.
    public var setting: AccountSetting?
    /// Where the item is managed on the vendor's site.
    public var url: URL?
    /// Extra facts for the row: a version, the servers a plugin brings.
    public var facts: [String]

    public init(
        provider: AccountProvider, kind: AccountItemKind, key: String, name: String, detail: String? = nil,
        state: AccountItemState, setting: AccountSetting? = nil, url: URL? = nil, facts: [String] = []
    ) {
        self.provider = provider
        self.kind = kind
        self.key = key
        self.name = name
        self.detail = detail
        self.state = state
        self.setting = setting
        self.url = url
        self.facts = facts
    }

    public var id: String { "\(provider.rawValue):\(kind.rawValue):\(key)" }

    /// The preference that would name this item's switch.
    /// The switch a choice about this item records, or nil when there is
    /// none or its name is one the portable document could not hold (a
    /// connector name with a quote in it, an app ID that is not a bare TOML
    /// key), so no row offers a choice that would fail to save.
    public var preferenceKey: AccountPreferenceKey? {
        guard let setting, setting.provider == provider, setting.requiresSubject,
            AccountPreferences.isValidSubject(key, for: setting)
        else { return nil }
        return AccountPreferenceKey(provider: provider, setting: setting, subject: key)
    }
}

/// What one Mac's client showed of one account, at one moment.
///
/// Never stored in the portable document and never synced: the account syncs
/// itself, so every Mac reads its own copy. What other Macs learn is the much
/// smaller `PublishedAccountSummary`.
public struct AccountObservation: Hashable, Sendable {
    public var provider: AccountProvider
    public var observedAt: Date
    /// Nil when the client's tool could not be found or run at all.
    public var clientVersion: String?
    public var signIn: AccountSignIn?
    public var items: [AccountItem]
    /// The value each switch has on this Mac, as the client will use it: the
    /// file this app edits, any layer above it, and the client's own report
    /// of an item's state. A key that is absent is unset.
    public var switches: [AccountPreferenceKey: AccountPreferenceValue]
    /// What the one file this app edits (`~/.claude/settings.json`,
    /// `~/.codex/config.toml`) itself says for each switch. Turning a switch
    /// back on removes the key when this file is what turned it off.
    public var fileValues: [AccountPreferenceKey: AccountPreferenceValue]
    /// Switches an organization's managed settings fix on this Mac. A local
    /// file underneath them cannot change what the client does.
    public var constrained: [AccountPreferenceKey: String]
    /// Lines worth reading: a list that could not be fetched, a sync turned off.
    public var notes: [String]
    /// Why nothing could be read, when nothing could.
    public var unavailableReason: String?
    /// How many directory entries the client listed that are not on the
    /// account. Shown as a count, never as rows.
    public var directoryCount: Int
    /// Why a switch for this provider cannot be written on this Mac at all,
    /// such as a configuration directory this app does not edit.
    public var writeBlocker: String?
    /// Whether the account's contents were read, as opposed to only how the
    /// client signs in and what its switches say. A light read leaves this
    /// false, and an empty item list then means "not read", never "none".
    public var contentsRead: Bool
    /// Variables the person's login shell exports that change what the client
    /// does in a terminal: an API key that replaces the subscription, a second
    /// configuration folder. Names only; a value is never read.
    public var shellOverrides: [AccountShellOverride]

    public init(
        provider: AccountProvider, observedAt: Date = .now, clientVersion: String? = nil, signIn: AccountSignIn? = nil,
        items: [AccountItem] = [], switches: [AccountPreferenceKey: AccountPreferenceValue] = [:],
        fileValues: [AccountPreferenceKey: AccountPreferenceValue] = [:],
        constrained: [AccountPreferenceKey: String] = [:], notes: [String] = [], unavailableReason: String? = nil,
        directoryCount: Int = 0, writeBlocker: String? = nil, contentsRead: Bool = false,
        shellOverrides: [AccountShellOverride] = []
    ) {
        self.provider = provider
        self.observedAt = observedAt
        self.clientVersion = clientVersion
        self.signIn = signIn
        self.items = items
        self.switches = switches
        self.fileValues = fileValues
        self.constrained = constrained
        self.notes = notes
        self.unavailableReason = unavailableReason
        self.directoryCount = directoryCount
        self.writeBlocker = writeBlocker
        self.contentsRead = contentsRead
        self.shellOverrides = shellOverrides
    }

    public func items(_ kind: AccountItemKind) -> [AccountItem] {
        items.filter { $0.kind == kind }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var reachesAccount: Bool { signIn?.method.reachesAccount == true }

    /// The value a switch has on this Mac: what its file says, or the
    /// vendor's documented default when the file says nothing. Nil when the
    /// file is silent and the vendor documents no default.
    public func effectiveValue(of key: AccountPreferenceKey) -> AccountPreferenceValue? {
        switches[key] ?? key.setting.documentedDefault
    }
}

// MARK: - Shared choices

/// One switch this app can set on every Mac. Each names the client setting it
/// writes; nothing here is invented, and each was read from the vendor's own
/// settings reference.
public enum AccountSetting: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    /// Claude Code `syncClaudeAiSkills` (user settings).
    case skillSync
    /// Claude Code `syncClaudeAiPlugins` (user settings).
    case pluginSync
    /// Claude Code `disableClaudeAiConnectors`, inverted: off means disabled.
    case connectors
    /// Claude Code `enabledPlugins["<subject>@synced"]`.
    case plugin
    /// Claude Code `deniedMcpServers` entry `{"serverName": "claude.ai <subject>"}`.
    case connector
    /// Codex `[features] apps`.
    case apps
    /// Codex `[apps.<subject>] enabled`.
    case app
    /// Codex `destructive_enabled` for one app, or `_default` with no subject.
    case destructiveTools
    /// Codex `open_world_enabled` for one app, or `_default` with no subject.
    case openWorldTools
    /// Codex `default_tools_approval_mode` for one app, or `_default`.
    case approvalMode

    public var id: String { rawValue }

    public var provider: AccountProvider {
        switch self {
        case .skillSync, .pluginSync, .connectors, .plugin, .connector: .claude
        case .apps, .app, .destructiveTools, .openWorldTools, .approvalMode: .chatGPT
        }
    }

    /// The setting is about one item and must name it.
    public var requiresSubject: Bool {
        switch self {
        case .plugin, .connector, .app: true
        default: false
        }
    }

    /// The setting may name one item, and otherwise means every item.
    public var allowsSubject: Bool {
        switch self {
        case .plugin, .connector, .app, .destructiveTools, .openWorldTools, .approvalMode: true
        default: false
        }
    }

    /// What an unset switch means to its client, where the vendor documents
    /// it. Nil where the reference names the setting without saying what an
    /// absent key does; the planner then writes the chosen value explicitly
    /// rather than assuming one.
    public var documentedDefault: AccountPreferenceValue? {
        switch self {
        // "Default: unset, so sessions signed in with your claude.ai account
        // sync" (syncClaudeAiSkills / syncClaudeAiPlugins); "Default: false,
        // so Claude Code fetches your connectors" (disableClaudeAiConnectors);
        // a synced plugin is "on unless ... a settings file sets false"; a
        // connector loads unless a deniedMcpServers entry names it.
        case .skillSync, .pluginSync, .connectors, .plugin, .connector: .on
        // `features.apps`: "stable; on by default"; `apps.<id>.enabled`:
        // "(default: true)".
        case .apps, .app: .on
        case .destructiveTools, .openWorldTools, .approvalMode: nil
        }
    }

    public var acceptedValues: [AccountPreferenceValue] {
        switch self {
        case .approvalMode: [.auto, .prompt, .writes, .approve]
        default: [.on, .off]
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum AccountPreferenceValue: String, Codable, CaseIterable, Sendable {
    case on
    case off
    /// Codex approval modes, verified in the Codex configuration reference.
    case auto
    case prompt
    case writes
    case approve

    public var label: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .auto: "Run without asking"
        case .prompt: "Ask every time"
        case .writes: "Ask before changes"
        case .approve: "Ask for approval"
        }
    }
}

/// Which switch a preference names: the provider, the setting and, for a
/// setting about one item, that item.
public struct AccountPreferenceKey: Codable, Hashable, Sendable, Comparable {
    public var provider: AccountProvider
    public var setting: AccountSetting
    public var subject: String?

    public init(provider: AccountProvider, setting: AccountSetting, subject: String? = nil) {
        self.provider = provider
        self.setting = setting
        self.subject = subject
    }

    public init(_ setting: AccountSetting, subject: String? = nil) {
        self.init(provider: setting.provider, setting: setting, subject: subject)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
        if lhs.setting != rhs.setting { return lhs.setting < rhs.setting }
        return (lhs.subject ?? "") < (rhs.subject ?? "")
    }

    /// A stable object identity for this key, so a sync conflict about one
    /// switch can name it the way every other conflict names its record.
    public var objectID: WorkspaceObjectID {
        var bytes = Data("agent-tooling.account-preference-key.v1\n".utf8)
        // A key that names no item and one that names "" are different keys,
        // so presence is part of the identity, not only the text.
        for field in [provider.rawValue, setting.rawValue, subject.map { "+" + $0 } ?? "-"] {
            bytes.append(Data("\(field.utf8.count):".utf8))
            bytes.append(Data(field.utf8))
        }
        return WorkspaceObjectID.stampingVersion8(digestPrefix: Array(SHA256.hash(data: bytes).prefix(16)))
    }

    /// The switch in words, for a plan step and a conflict.
    public var label: String {
        let item = subject ?? ""
        switch setting {
        case .skillSync: return "claude.ai skills in Claude Code"
        case .pluginSync: return "claude.ai plugins in Claude Code"
        case .connectors: return "claude.ai connectors in Claude Code"
        case .plugin: return "the \(item) plugin in Claude Code"
        case .connector: return "the \(item) connector in Claude Code"
        case .apps: return "ChatGPT apps in Codex"
        case .app: return "the \(item) app in Codex"
        case .destructiveTools:
            return subject == nil ? "tools that delete or change things, for every app" : "tools that delete or change things in \(item)"
        case .openWorldTools:
            return subject == nil ? "tools that reach the open web, for every app" : "tools that reach the open web in \(item)"
        case .approvalMode: return subject == nil ? "when Codex asks before an app tool runs" : "when Codex asks before a \(item) tool runs"
        }
    }
}

/// A switch the person wants the same on every Mac.
public struct AccountPreference: Codable, Hashable, Sendable {
    public var provider: AccountProvider
    public var setting: AccountSetting
    public var subject: String?
    public var value: AccountPreferenceValue

    public init(provider: AccountProvider, setting: AccountSetting, subject: String? = nil, value: AccountPreferenceValue) {
        self.provider = provider
        self.setting = setting
        self.subject = subject
        self.value = value
    }

    public init(_ key: AccountPreferenceKey, value: AccountPreferenceValue) {
        self.init(provider: key.provider, setting: key.setting, subject: key.subject, value: value)
    }

    public var key: AccountPreferenceKey { .init(provider: provider, setting: setting, subject: subject) }
}

/// The portable record of the person's account choices: one entry per switch
/// they decided, and nothing for a switch they left to each Mac.
public struct AccountPreferences: Codable, Hashable, Sendable {
    public static let maximumEntries = 512

    public var entries: [AccountPreference]

    public init(entries: [AccountPreference] = []) {
        self.entries = entries
    }

    public func value(for key: AccountPreferenceKey) -> AccountPreferenceValue? {
        entries.first { $0.key == key }?.value
    }

    public var isEmpty: Bool { entries.isEmpty }

    func canonicalized() -> Self {
        var value = self
        value.entries.sort { $0.key < $1.key }
        return value
    }

    func validate() throws {
        guard entries.count <= Self.maximumEntries else {
            throw WorkspaceDomainValidationError.invalidField("account preference count")
        }
        var seen = Set<AccountPreferenceKey>()
        for entry in entries {
            try Self.validate(entry)
            guard seen.insert(entry.key).inserted else {
                throw WorkspaceDomainValidationError.duplicate("account preference")
            }
        }
    }

    static func validate(_ entry: AccountPreference) throws {
        guard entry.setting.provider == entry.provider else {
            throw WorkspaceDomainValidationError.invalidField("account preference provider")
        }
        guard entry.setting.acceptedValues.contains(entry.value) else {
            throw WorkspaceDomainValidationError.invalidField("account preference value")
        }
        switch (entry.subject, entry.setting.requiresSubject, entry.setting.allowsSubject) {
        case (nil, true, _):
            throw WorkspaceDomainValidationError.missingReference("account preference subject")
        case (.some, _, false):
            throw WorkspaceDomainValidationError.invalidField("account preference subject")
        case (.some(let subject), _, true):
            guard isValidSubject(subject, for: entry.setting) else {
                throw WorkspaceDomainValidationError.invalidField("account preference subject")
            }
        default:
            break
        }
    }

    /// A subject is written into a client's own settings file, so each kind
    /// has the narrowest shape that fits what the vendor names it with.
    public static func isValidSubject(_ subject: String, for setting: AccountSetting) -> Bool {
        switch setting {
        case .plugin:
            return subject.count <= 256 && !subject.contains("@")
                && OperationCommandPolicy.isSafePluginIdentifier(subject)
        case .connector:
            return isValidConnectorName(subject)
        case .app, .destructiveTools, .openWorldTools, .approvalMode:
            return isValidAppID(subject)
        case .skillSync, .pluginSync, .connectors, .apps:
            return false
        }
    }

    /// A connector's display name as claude.ai shows it: free text, so only
    /// its length and characters are bounded.
    public static func isValidConnectorName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && trimmed == name && name.count <= 200
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\"" || $0 == "\\" })
    }

    /// A Codex app id becomes a TOML table name, `[apps.<id>]`, so it is
    /// limited to the characters a bare TOML key allows and never `_default`.
    public static func isValidAppID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id != "_default"
            && id.unicodeScalars.allSatisfy { scalar in
                (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || "_-".unicodeScalars.contains(scalar)
            }
    }
}

// MARK: - What other Macs learn

/// The part of an account observation this Mac publishes to the others.
///
/// It carries enough to say "every Mac uses the same account" and "every Mac
/// follows the shared choices" without publishing an address, a list of what
/// the account holds, or a credential of any kind.
public struct PublishedAccountSummary: Codable, Hashable, Sendable {
    public var provider: AccountProvider
    public var signInMethod: AccountSignIn.Method
    public var plan: String?
    /// A salted digest of the account's identity; equal on two Macs exactly
    /// when they are signed in to the same account in the same organization.
    public var accountFingerprint: String?
    /// How many of each kind the account held, keyed by `AccountItemKind`
    /// raw value. Nil when this Mac had only read how the client signs in.
    public var itemCounts: [String: Int]?
    /// Shared choices this Mac's own settings did not yet follow when it
    /// published. Nil when it had nothing to compare.
    public var switchesOutOfStep: Int?
    /// Names of login-shell variables that take a terminal session off the
    /// subscription or onto another configuration folder. Never a value.
    public var shellOverrides: [String]?
    public var observedAt: Date

    public init(
        provider: AccountProvider, signInMethod: AccountSignIn.Method, plan: String?, accountFingerprint: String?,
        itemCounts: [String: Int]?, switchesOutOfStep: Int?, shellOverrides: [String]? = nil, observedAt: Date
    ) {
        self.provider = provider
        self.signInMethod = signInMethod
        self.plan = plan
        self.accountFingerprint = accountFingerprint
        self.itemCounts = itemCounts
        self.switchesOutOfStep = switchesOutOfStep
        self.shellOverrides = shellOverrides
        self.observedAt = observedAt
    }

    public init(observation: AccountObservation, workspaceID: WorkspaceObjectID, switchesOutOfStep: Int?) {
        let counts =
            observation.contentsRead
            ? Dictionary(
                uniqueKeysWithValues: AccountItemKind.allCases.compactMap { kind -> (String, Int)? in
                    let count = observation.items(kind).count
                    return count == 0 ? nil : (kind.rawValue, count)
                })
            : nil
        let overrides = observation.shellOverrides.map(\.variable)
        self.init(
            provider: observation.provider,
            signInMethod: observation.signIn?.method ?? .unknown,
            plan: observation.signIn?.method == .subscription ? observation.signIn?.plan : nil,
            accountFingerprint: Self.fingerprint(
                provider: observation.provider, signIn: observation.signIn, workspaceID: workspaceID),
            itemCounts: counts,
            switchesOutOfStep: switchesOutOfStep,
            shellOverrides: overrides.isEmpty ? nil : overrides,
            observedAt: observation.observedAt)
    }

    public func count(of kind: AccountItemKind) -> Int? {
        itemCounts.map { $0[kind.rawValue] ?? 0 }
    }

    /// Salted with the workspace so the value means nothing outside it, and
    /// truncated because only equality is ever asked of it.
    public static func fingerprint(
        provider: AccountProvider, signIn: AccountSignIn?, workspaceID: WorkspaceObjectID
    ) -> String? {
        guard let signIn, signIn.method == .subscription,
            let email = signIn.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty
        else { return nil }
        var bytes = Data("agent-tooling.account-fingerprint.v1\n".utf8)
        for field in [workspaceID.rawValue.uuidString.lowercased(), provider.rawValue, email, signIn.organizationID ?? ""] {
            bytes.append(Data("\(field.utf8.count):".utf8))
            bytes.append(Data(field.utf8))
        }
        return SHA256.hash(data: bytes).prefix(12).lowercaseHex
    }
}

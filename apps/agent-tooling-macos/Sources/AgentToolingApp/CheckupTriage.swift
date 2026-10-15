import AgentToolingCore
import Foundation

/// One row on the Checkup screen: a group of findings, or one recommendation,
/// with the one thing to do about all of it.
///
/// 257 findings are not 257 decisions. The assistant's recommendations already
/// speak for whole groups; what they do not cover is grouped by kind and app.
/// Each item lands in one of three buckets so the screen can say how much is
/// actually left to do.
struct CheckupItem: Identifiable, Equatable {
    enum Bucket: Int, CaseIterable, Comparable {
        /// The audit and the assistant agree, and the app can do it.
        case fix
        /// Needs a person: a judgment, or a screen to open.
        case decide
        /// The assistant says leave these alone, or there is nothing to do.
        case fine

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .fix: "To fix"
            case .decide: "To decide"
            case .fine: "Fine as they are"
            }
        }
    }

    let id: String
    let bucket: Bucket
    let client: ClientKind?
    let title: String
    /// One or two sentences. The wall of text lives behind a disclosure.
    let detail: String
    let findings: [SetupFinding]
    let recommendation: SetupRecommendation?
    /// What the primary button runs: one action per finding, or one for the
    /// recommendation. Empty when the primary is "dismiss all".
    let actions: [SetupAction]
    let settings: [(client: ClientKind, key: String, value: String)]
    let primaryTitle: String?
    let provenance: SetupRecommendationProvenance?
    /// The screen a row opens instead of running something.
    let opens: AppSection?

    static func == (lhs: CheckupItem, rhs: CheckupItem) -> Bool {
        lhs.id == rhs.id && lhs.bucket == rhs.bucket && lhs.title == rhs.title && lhs.findings == rhs.findings
            && lhs.actions == rhs.actions && lhs.primaryTitle == rhs.primaryTitle
    }

    var count: Int { max(findings.count, 1) }
    var severity: SetupFinding.Severity { findings.map(\.severity).max() ?? .info }
    /// Whether the primary button changes files on this Mac.
    var changesFiles: Bool { actions.contains(where: \.changesFiles) || !settings.isEmpty }
    var canRun: Bool { !actions.isEmpty || !settings.isEmpty }
}

enum CheckupTriage {
    static func items(from checkup: SetupCheckup) -> [CheckupItem] {
        let findings = Dictionary(uniqueKeysWithValues: checkup.openFindings.map { ($0.id, $0) })
        var covered = Set<String>()
        var items: [CheckupItem] = []

        // The assistant first: each recommendation is one row, over the
        // findings it named.
        for recommendation in checkup.openRecommendations {
            let mine = recommendation.findingIDs.compactMap { findings[$0] }
            covered.formUnion(mine.map(\.id))
            items.append(item(for: recommendation, over: mine))
        }

        // Everything it did not speak to, grouped by kind and app. A skill two
        // plugins both carry and a loose copy beside a plugin's are different
        // rows: one has nothing to do, the other has a button.
        let rest = checkup.openFindings.filter { !covered.contains($0.id) }
        let groups = Dictionary(grouping: rest) {
            GroupKey(
                kind: $0.kind, client: $0.client,
                removable: [.duplicateSkillInClient, .mcpServerDefinedSeveralTimes].contains($0.kind) ? !$0.actions.isEmpty : true)
        }
        for (key, group) in groups {
            items.append(item(for: key, group: group.sorted { $0.subject < $1.subject }))
        }

        return items.sorted { lhs, rhs in
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.title < rhs.title
        }
    }

    /// One recommendation as a row, over whichever of the audit's findings it
    /// named. For a client review, whose recommendations are kept apart from
    /// the checkup.
    static func item(for recommendation: SetupRecommendation, audit: SetupAuditReport?) -> CheckupItem {
        let findings = Dictionary(uniqueKeysWithValues: (audit?.findings ?? []).map { ($0.id, $0) })
        return item(for: recommendation, over: recommendation.findingIDs.compactMap { findings[$0] })
    }

    private struct GroupKey: Hashable {
        let kind: SetupFinding.Kind
        let client: ClientKind?
        let removable: Bool
    }

    // MARK: A recommendation

    private static func item(for recommendation: SetupRecommendation, over findings: [SetupFinding]) -> CheckupItem {
        switch recommendation.action {
        case .take(let action):
            // The assistant chose one finding's action; the same kind of action
            // on every finding it named is what "do this" means for the group.
            let actions = findings.isEmpty ? [action] : findings.compactMap { finding in finding.actions.first { sameKind($0, action) } ?? nil }
            let distinct = actions.isEmpty ? [action] : actions
            return CheckupItem(
                id: recommendation.id, bucket: distinct.allSatisfy(\.changesFiles) || distinct.contains(where: isCheck) ? .fix : .decide,
                client: recommendation.client, title: recommendation.title, detail: recommendation.summary, findings: findings,
                recommendation: recommendation, actions: distinct, settings: [],
                primaryTitle: bulkTitle(distinct), provenance: recommendation.provenance, opens: opensScreen(distinct.first))
        case .installPlugin(let client, let pluginID):
            return CheckupItem(
                id: recommendation.id, bucket: .fix, client: client, title: recommendation.title, detail: recommendation.summary,
                findings: findings, recommendation: recommendation, actions: [.reinstallPlugin(pluginID: pluginID, client: client)], settings: [],
                primaryTitle: "Install", provenance: recommendation.provenance, opens: nil)
        case .disableMCPServer(let client, let name):
            return CheckupItem(
                id: recommendation.id, bucket: .fix, client: client, title: recommendation.title, detail: recommendation.summary,
                findings: findings, recommendation: recommendation, actions: [.disableMCPServer(name: name, client: client)], settings: [],
                primaryTitle: "Turn off", provenance: recommendation.provenance, opens: nil)
        case .setSetting(let client, let key, let value):
            return CheckupItem(
                id: recommendation.id, bucket: .fix, client: client, title: recommendation.title, detail: recommendation.summary,
                findings: findings, recommendation: recommendation, actions: [], settings: [(client, key, value)],
                primaryTitle: "Set \(key)", provenance: recommendation.provenance, opens: nil)
        case .readOnly:
            // "Leave these alone" or plain information: fine, dismiss together.
            return CheckupItem(
                id: recommendation.id, bucket: .fine, client: recommendation.client, title: recommendation.title, detail: recommendation.summary,
                findings: findings, recommendation: recommendation, actions: [], settings: [],
                primaryTitle: nil, provenance: recommendation.provenance, opens: nil)
        }
    }

    // MARK: A group the assistant did not speak to

    private static func item(for key: GroupKey, group: [SetupFinding]) -> CheckupItem {
        let count = group.count
        let client = key.client
        let id = "group:\(key.kind.rawValue):\(client?.rawValue ?? "-")" + (key.removable ? "" : ":plugins")
        let actions = group.compactMap(\.actions.first)
        switch key.kind {
        case .brokenSkillLink, .skillWithoutDefinition, .stalePluginCache, .missingPluginInstall, .toolUnavailable, .neverChecked:
            return CheckupItem(
                id: id, bucket: .fix, client: client, title: groupTitle(key.kind, count: count), detail: groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: actions, settings: [], primaryTitle: bulkTitle(actions),
                provenance: .audit(findingID: group[0].id), opens: nil)
        case .duplicateSkillInClient:
            // Only a standalone copy can be removed; a skill two plugins both
            // carry is the plugins' business.
            guard key.removable else {
                return CheckupItem(
                    id: id, bucket: .fine, client: client,
                    title: count == 1 ? "A skill more than one plugin carries" : "\(count) skills more than one plugin carries",
                    detail: "Each copy comes with a plugin, or was placed by a tool that keeps it in step, so there is nothing here to remove. \(client?.rawValue ?? "The app") lists every copy.",
                    findings: group, recommendation: nil, actions: [], settings: [], primaryTitle: nil, provenance: .audit(findingID: group[0].id), opens: nil)
            }
            return CheckupItem(
                id: id, bucket: .fix, client: client, title: count == 1 ? "A loose copy of a skill" : "\(count) loose copies of skills",
                detail: groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: actions, settings: [], primaryTitle: bulkTitle(actions),
                provenance: .audit(findingID: group[0].id), opens: nil)
        case .unmanagedSkill:
            return CheckupItem(
                id: id, bucket: .decide, client: client, title: groupTitle(key.kind, count: count), detail: groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: actions, settings: [],
                primaryTitle: count == 1 ? "Add to library" : "Add all \(count) to library", provenance: .audit(findingID: group[0].id), opens: nil)
        case .unreachableMCPCommand:
            let offs = group.compactMap { finding in finding.actions.first { if case .disableMCPServer = $0 { return true }; return false } }
            return CheckupItem(
                id: id, bucket: .decide, client: client, title: groupTitle(key.kind, count: count), detail: groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: offs, settings: [],
                primaryTitle: offs.isEmpty ? nil : (offs.count == 1 ? "Turn it off" : "Turn off all \(offs.count)"),
                provenance: .audit(findingID: group[0].id), opens: .mcpServers)
        case .mcpServerRepeatedAcrossClients:
            return CheckupItem(
                id: id, bucket: .decide, client: nil, title: groupTitle(key.kind, count: count), detail: groupDetail(key.kind, client: nil),
                findings: group, recommendation: nil, actions: [], settings: [], primaryTitle: nil,
                provenance: .audit(findingID: group[0].id), opens: .mcpServers)
        case .mcpServerDefinedSeveralTimes:
            // Only a copy in the app's own configuration is a person's to
            // remove; servers that only plugins bring are the plugins'.
            return CheckupItem(
                id: id, bucket: key.removable ? .decide : .fine, client: client, title: groupTitle(key.kind, count: count),
                detail: key.removable
                    ? groupDetail(key.kind, client: client)
                    : "\(client?.rawValue ?? "The app") gets each of these from more than one plugin. Each plugin's copy is the plugin's, so there is nothing here to remove.",
                findings: group, recommendation: nil, actions: [], settings: [], primaryTitle: nil,
                provenance: .audit(findingID: group[0].id), opens: key.removable ? .mcpServers : nil)
        case .pluginSkillsOverlap:
            return CheckupItem(
                id: id, bucket: .decide, client: client, title: groupTitle(key.kind, count: count), detail: groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: [], settings: [], primaryTitle: nil,
                provenance: .audit(findingID: group[0].id), opens: .plugins)
        case .accountChoicesNotFollowed:
            // Applying is a reviewed edit of the app's own settings file. A
            // choice this Mac cannot follow by editing one is the person's to
            // look at on the Accounts tab.
            let applies = actions.filter { if case .applyAccountChoices = $0 { return true }; return false }
            return CheckupItem(
                id: id, bucket: applies.isEmpty ? .decide : .fix, client: client,
                title: group.count == 1 ? group[0].title : groupTitle(key.kind, count: count),
                detail: group.count == 1 ? group[0].detail : groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: applies, settings: [],
                primaryTitle: applies.isEmpty ? "Open Accounts" : bulkTitle(applies),
                provenance: .audit(findingID: group[0].id), opens: .accounts)
        case .accountSignIn, .accountShellOverride, .accountDiffersFromOtherMacs, .accountConnectorNeedsSignIn:
            // Signing in, a shell profile, and an account connector are all
            // changed outside this app, so these rows open Accounts.
            return CheckupItem(
                id: id, bucket: .decide, client: client,
                title: group.count == 1 ? group[0].title : groupTitle(key.kind, count: count),
                detail: group.count == 1 ? group[0].detail : groupDetail(key.kind, client: client),
                findings: group, recommendation: nil, actions: [], settings: [], primaryTitle: "Open Accounts",
                provenance: .audit(findingID: group[0].id), opens: .accounts)
        }
    }

    // MARK: Words

    static func groupTitle(_ kind: SetupFinding.Kind, count: Int) -> String {
        let one = count == 1
        return switch kind {
        case .brokenSkillLink: one ? "A skill link that points at nothing" : "\(count) skill links that point at nothing"
        case .missingPluginInstall: one ? "A plugin whose files are gone" : "\(count) plugins whose files are gone"
        case .duplicateSkillInClient: one ? "A skill reachable two ways" : "\(count) skills reachable two ways"
        case .unmanagedSkill: one ? "A skill not managed by this app" : "\(count) skills not managed by this app"
        case .unreachableMCPCommand: one ? "An MCP server that cannot start" : "\(count) MCP servers that cannot start"
        case .stalePluginCache: one ? "Old plugin versions on disk" : "Old versions of \(count) plugins on disk"
        case .toolUnavailable: "The app's command could not be run"
        case .neverChecked: "Never checked"
        case .skillWithoutDefinition: one ? "An empty skill folder" : "\(count) empty skill folders"
        case .mcpServerRepeatedAcrossClients: one ? "A server configured in several apps" : "\(count) servers configured in several apps"
        case .mcpServerDefinedSeveralTimes: one ? "A server the app gets from several places" : "\(count) servers the app gets from several places"
        case .pluginSkillsOverlap: one ? "Two plugins that carry the same skills" : "\(count) pairs of plugins that carry the same skills"
        case .accountSignIn: one ? "An app not signed in with its account" : "\(count) apps not signed in with their accounts"
        case .accountShellOverride: one ? "A shell variable that changes an app's sign-in" : "\(count) shell variables that change an app's sign-in"
        case .accountChoicesNotFollowed: one ? "Shared account choices not applied here" : "Shared account choices not applied in \(count) apps"
        case .accountDiffersFromOtherMacs: one ? "A different account from your other Macs" : "\(count) accounts that differ from your other Macs"
        case .accountConnectorNeedsSignIn: one ? "Account connectors that need attention" : "Account connectors in \(count) accounts that need attention"
        }
    }

    static func groupDetail(_ kind: SetupFinding.Kind, client: ClientKind?) -> String {
        let app = client?.rawValue ?? "The app"
        switch kind {
        case .brokenSkillLink: return "Links in \(app)'s skills folder to folders that are no longer there. \(app) skips them. Removing a link touches nothing else."
        case .missingPluginInstall: return "\(app) records these plugins at folders that do not exist. Reinstalling runs its own install command."
        case .duplicateSkillInClient: return "\(app) can reach each of these by two paths, and which one it uses depends on load order. Removing the loose copy moves it to Agent Tooling's trash; the plugin's copy stays."
        case .unmanagedSkill: return "\(app) has these skills but the library holds no copy, so they cannot be placed in another app, edited here, or checked for updates. Adding copies the files in; \(app)'s folder is not changed."
        case .unreachableMCPCommand: return "Their start commands are not on this Mac in any place the app knows to look, so they fail to start. Turning one off keeps its configuration."
        case .stalePluginCache: return "Only one version of each is in use; the others take space. Removing moves them to Agent Tooling's trash."
        case .toolUnavailable: return "Its configuration was read from disk, but without the command the app cannot confirm its version or ask it what is installed."
        case .neverChecked: return "This Mac manages \(app) but has never read what it holds."
        case .skillWithoutDefinition: return "Folders in \(app)'s skills folder with no SKILL.md. \(app) does not load them. Removing moves them to Agent Tooling's trash."
        case .mcpServerRepeatedAcrossClients: return "Each app has its own copy of these servers' configuration. Managed from the library, each would be one definition placed in every app."
        case .mcpServerDefinedSeveralTimes: return "\(app) gets each of these servers from its own configuration and from a plugin. Unless the two are configured identically, it runs both and lists both sets of tools. If the plugin's copy does what you need, the configured one can go."
        case .pluginSkillsOverlap: return "\(app) lists each plugin's copy of a shared skill, so these appear twice. Removing a plugin takes its other skills and servers with it, so that is yours to decide on the Plugins screen."
        case .accountSignIn: return "Only a subscription sign-in brings an account's connectors, skills, plugins and apps to the app. Sign in again from a terminal."
        case .accountShellOverride: return "Your login shell exports variables that change how the app signs in when it runs in a terminal. Agent Tooling reads only their names."
        case .accountChoicesNotFollowed: return "Every Mac shares these choices. Applying them changes each app's own settings file after backing it up."
        case .accountDiffersFromOtherMacs: return "Each Mac gets the contents of the account it signs in with, so these Macs do not have the same ones."
        case .accountConnectorNeedsSignIn: return "Account connectors are connected and signed in on the vendor's site, not from this Mac."
        }
    }

    /// What the one button on a group says.
    static func bulkTitle(_ actions: [SetupAction]) -> String? {
        guard let first = actions.first else { return nil }
        let n = actions.count
        switch first {
        case .adoptSkill: return n == 1 ? "Add to library" : "Add all \(n) to library"
        case .removeSkillCopy: return n == 1 ? "Remove the copy" : "Remove all \(n)"
        case .removeBrokenLink: return n == 1 ? "Remove the link" : "Remove all \(n)"
        case .reinstallPlugin: return n == 1 ? "Reinstall" : "Reinstall all \(n)"
        case .pruneStalePluginCache: return n == 1 ? "Remove old versions" : "Remove old versions of all \(n)"
        case .disableMCPServer: return n == 1 ? "Turn it off" : "Turn off all \(n)"
        case .checkClient: return "Check now"
        case .locateTool: return "Find the tool"
        case .inspectMCPServer, .manageMCPServer: return "Open Connections"
        case .applyAccountChoices: return n == 1 ? "Apply" : "Apply in all \(n)"
        case .openAccountSite(let provider, _): return "Open \(provider.accountName)"
        case .openAccounts: return "Open Accounts"
        }
    }

    private static func sameKind(_ lhs: SetupAction, _ rhs: SetupAction) -> Bool {
        switch (lhs, rhs) {
        case (.adoptSkill, .adoptSkill), (.removeSkillCopy, .removeSkillCopy), (.removeBrokenLink, .removeBrokenLink),
            (.reinstallPlugin, .reinstallPlugin), (.pruneStalePluginCache, .pruneStalePluginCache), (.inspectMCPServer, .inspectMCPServer),
            (.disableMCPServer, .disableMCPServer), (.locateTool, .locateTool), (.checkClient, .checkClient), (.manageMCPServer, .manageMCPServer),
            (.applyAccountChoices, .applyAccountChoices), (.openAccountSite, .openAccountSite), (.openAccounts, .openAccounts):
            true
        default: false
        }
    }

    private static func isCheck(_ action: SetupAction) -> Bool {
        switch action {
        case .checkClient, .locateTool: true
        default: false
        }
    }

    private static func opensScreen(_ action: SetupAction?) -> AppSection? {
        switch action {
        case .inspectMCPServer, .manageMCPServer: .mcpServers
        case .openAccounts, .openAccountSite: .accounts
        default: nil
        }
    }

    // MARK: Fix all

    /// Everything in the fix bucket, as one plan the person confirms once.
    struct FixAllPlan {
        let items: [CheckupItem]
        var actions: [SetupAction] { items.flatMap(\.actions) }
        var settings: [(client: ClientKind, key: String, value: String)] { items.flatMap(\.settings) }
        var isEmpty: Bool { actions.isEmpty && settings.isEmpty }
        var total: Int { actions.count + settings.count }

        /// What it will do, counted by kind, in the words a person reads
        /// before confirming.
        var lines: [String] {
            var counts: [String: Int] = [:]
            var order: [String] = []
            func add(_ label: String) {
                if counts[label] == nil { order.append(label) }
                counts[label, default: 0] += 1
            }
            for action in actions {
                switch action {
                case .adoptSkill: add("Copy a skill into the library")
                case .removeSkillCopy: add("Move a skill folder to Agent Tooling's trash")
                case .removeBrokenLink: add("Remove a dead link")
                case .reinstallPlugin: add("Run an app's plugin install command")
                case .pruneStalePluginCache(let paths, _): for _ in paths { add("Move an old plugin version to the trash") }
                case .disableMCPServer: add("Turn an MCP server off in its app's configuration (backed up first)")
                case .checkClient: add("Check an app")
                case .locateTool: add("Look for an app's command")
                case .applyAccountChoices: add("Change an app's account settings in its own settings file (backed up first)")
                case .inspectMCPServer, .manageMCPServer, .openAccountSite, .openAccounts: break
                }
            }
            for _ in settings { add("Change a setting in an app's configuration file (backed up first)") }
            return order.map { label in
                let n = counts[label] ?? 0
                return n == 1 ? label : "\(label) × \(n)"
            }
        }
    }

    static func fixAll(_ items: [CheckupItem]) -> FixAllPlan {
        FixAllPlan(items: items.filter { $0.bucket == .fix && $0.canRun })
    }
}

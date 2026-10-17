import Foundation

/// What another Mac last said about its accounts, for comparison here.
public struct AccountPeerReport: Hashable, Sendable {
    public var deviceName: String
    public var summaries: [PublishedAccountSummary]

    public init(deviceName: String, summaries: [PublishedAccountSummary]) {
        self.deviceName = deviceName
        self.summaries = summaries
    }
}

/// Turns what this Mac's clients said about their hosted accounts into
/// Checkup findings. Deterministic and read-only, like the setup audit: each
/// finding is a fact a script proved, with its evidence attached.
public enum AccountAuditor {
    public static func findings(
        observations: [AccountObservation],
        plans: [AccountProvider: AccountPreferencePlan],
        peers: [AccountPeerReport],
        workspaceID: WorkspaceObjectID
    ) -> [SetupFinding] {
        var findings: [SetupFinding] = []
        for observation in observations.sorted(by: { $0.provider < $1.provider }) {
            let provider = observation.provider
            let client = provider.client
            guard observation.unavailableReason == nil, let signIn = observation.signIn else { continue }

            if !signIn.method.reachesAccount {
                findings.append(
                    SetupFinding(
                        kind: .accountSignIn, severity: .medium, client: client, subject: provider.rawValue,
                        title: "\(client.rawValue) is not signed in with \(provider.accountName)",
                        detail:
                            "It uses \(signIn.summary(for: provider)), so your \(provider.accountName) \(provider == .claude ? "connectors, skills and plugins do" : "apps do") not reach it on this Mac. Sign in with \(provider == .claude ? "`claude auth login`" : "`codex login`") in a terminal.",
                        evidence: [signIn.method.rawValue] + (signIn.provider.map { [$0] } ?? []),
                        actions: [.openAccounts(provider: provider)]))
            }

            for override in observation.shellOverrides {
                findings.append(
                    SetupFinding(
                        kind: .accountShellOverride, severity: override.replacesSubscription ? .medium : .low,
                        client: client, subject: "\(provider.rawValue):\(override.variable)",
                        title: "Your login shell sets \(override.variable)",
                        detail: override.consequence + " Agent Tooling reads only the variable's name, never its value.",
                        evidence: [override.variable], actions: [.openAccounts(provider: provider)]))
            }

            if let plan = plans[provider], plan.outOfStep > 0 {
                let changes = plan.changes.map(\.summary)
                let held = plan.held.map { "\($0.key.label): \($0.reason)" }
                findings.append(
                    SetupFinding(
                        kind: .accountChoicesNotFollowed, severity: .low, client: client, subject: provider.rawValue,
                        title:
                            "\(client.rawValue) does not follow \(plan.outOfStep) shared \(provider.accountName) choice\(plan.outOfStep == 1 ? "" : "s")",
                        detail: plan.changes.isEmpty
                            ? "Every Mac shares these choices, and this Mac cannot follow them by changing its own settings."
                            : "Every Mac shares these choices. Applying them changes \(plan.file.relativePath) after backing it up.",
                        evidence: Array((changes + held).prefix(20)),
                        actions: plan.changes.isEmpty ? [.openAccounts(provider: provider)] : [.applyAccountChoices(provider: provider)]))
            }

            if observation.contentsRead {
                let waiting = observation.items(.connector).filter { $0.state.tone == .attention }
                if !waiting.isEmpty {
                    findings.append(
                        SetupFinding(
                            kind: .accountConnectorNeedsSignIn, severity: .low, client: client, subject: provider.rawValue,
                            title: waiting.count == 1
                                ? "\(waiting[0].name) needs attention on \(provider.accountName)"
                                : "\(waiting.count) \(provider.accountName) connectors need attention",
                            detail:
                                "Account connectors are connected and signed in on \(provider.accountName); Claude Code cannot sign in to them itself.",
                            evidence: waiting.map { "\($0.name): \($0.state.label)" },
                            actions: [.openAccountSite(provider: provider, kind: .connector)]))
                }
            }

            guard let mine = PublishedAccountSummary.fingerprint(provider: provider, signIn: signIn, workspaceID: workspaceID) else {
                continue
            }
            let others = peers.compactMap { peer -> String? in
                guard let theirs = peer.summaries.first(where: { $0.provider == provider }),
                    theirs.signInMethod == .subscription,
                    let fingerprint = theirs.accountFingerprint, fingerprint != mine
                else { return nil }
                return peer.deviceName
            }
            if !others.isEmpty {
                findings.append(
                    SetupFinding(
                        kind: .accountDiffersFromOtherMacs, severity: .high, client: client, subject: provider.rawValue,
                        title: "This Mac uses a different \(provider.accountName) account from \(others.joined(separator: ", "))",
                        detail:
                            "Each Mac gets the connectors, skills and plugins of the account it signs in with, so these Macs do not have the same ones. Sign in to the same account on every Mac.",
                        evidence: others, actions: [.openAccounts(provider: provider)]))
            }
        }
        return findings
    }
}

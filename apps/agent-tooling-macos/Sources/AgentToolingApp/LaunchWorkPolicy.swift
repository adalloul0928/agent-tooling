import AgentToolingCore
import Foundation

/// Decides launch work from setup progress, device preferences, and hand-off hints.
/// Setup in progress starts no shell work. Deferred setup permits network catalogs
/// only after preferences were shown. A fresh stage read suppresses a duplicate
/// scan and audit. Assistant work follows the device's consent, including legacy
/// workspace defaults.
struct LaunchWorkPolicy: Equatable, Sendable {
    /// Whether the shell starts any launch work at all.
    let startsShellWork: Bool
    /// Whether this Mac's apps are checked as the shell opens.
    let checksApps: Bool
    /// Whether the Checkup audit runs as the shell opens.
    let auditsOnOpen: Bool
    /// Whether that audit may check the apps first, when nothing has been
    /// checked yet.
    let auditMayScan: Bool
    /// Whether the catalogs may be asked over the network: the update check
    /// and Home's catalog refresh. Held for a first run left for later before
    /// How Agent Tooling behaves was seen, where the person chose when to
    /// look for updates.
    let allowsNetworkCatalogs: Bool
    /// The assistant's runs in force.
    let consent: AssistantRunConsent
    /// Whether the shell opened straight from a setup walk that read this
    /// Mac's apps, whose read is then this launch's check.
    let takesStageRead: Bool

    /// A completed full scan counts for this launch; a partial post-install check
    /// and a check saved by an earlier launch do not. A hand-off from a stage that
    /// read the apps also counts, avoiding duplicate scans when windows reopen.
    static func decide(
        status: SetupStatus, preferences: DeviceWorkspacePreferences, hints: ShellLaunchHints,
        checkedThisLaunch: Bool = false
    ) -> LaunchWorkPolicy {
        let checkOnOpen = preferences.automaticallyCheckHealth
        let consent = preferences.effectiveAssistantRuns
        let catalogs = allowsNetworkCatalogs(status: status)
        switch status {
        case .inProgress:
            return LaunchWorkPolicy(
                startsShellWork: false, checksApps: false, auditsOnOpen: false, auditMayScan: false,
                allowsNetworkCatalogs: false, consent: consent, takesStageRead: false)
        case .legacy:
            return LaunchWorkPolicy(
                startsShellWork: true, checksApps: checkOnOpen && !checkedThisLaunch, auditsOnOpen: true,
                auditMayScan: checkOnOpen, allowsNetworkCatalogs: catalogs, consent: consent, takesStageRead: false)
        case .deferred, .finished:
            let fresh = !hints.justHandedOff
            return LaunchWorkPolicy(
                startsShellWork: true, checksApps: checkOnOpen && fresh && !checkedThisLaunch, auditsOnOpen: fresh,
                auditMayScan: checkOnOpen, allowsNetworkCatalogs: catalogs, consent: consent,
                takesStageRead: hints.justHandedOff)
        }
    }

    /// Whether the catalogs may be asked over the network, which Home's own
    /// catalog refresh asks too: not while a first run is on the stage, nor
    /// for a first run (Start here or Join) left for later before How Agent
    /// Tooling behaves was seen.
    static func allowsNetworkCatalogs(status: SetupStatus) -> Bool {
        switch status {
        case .legacy, .finished: true
        case .inProgress: false
        case .deferred(_, let path, let seenPreferences): path == .rerun || seenPreferences
        }
    }
}

extension LaunchWorkPolicy {
    /// Refreshes the library and apps, then audits. Updates and sync run alongside
    /// assistant work; deep dives and weekly reviews run sequentially.
    /// Consent is rechecked before sending summaries. Disabling a run cancels it
    /// through `recordAssistantRuns`, even during launch work.
    @MainActor
    func run(on workspace: WorkspaceLaunch.Workspace, syncPass: @escaping @MainActor () async -> Void) async {
        guard startsShellWork else { return }
        if takesStageRead { workspace.device.countStageReadAsThisLaunchsCheck() }
        async let library: Void = workspace.library.refresh()
        if checksApps {
            async let device: Void = workspace.device.refresh()
            _ = await (library, device)
        } else {
            await library
        }
        if auditsOnOpen { await workspace.setup.runScheduledAudit(allowsScan: auditMayScan) }
        async let local: Void = runLocalLane(on: workspace, syncPass: syncPass)
        async let assistant: Void = runAssistantLane(on: workspace)
        _ = await (local, assistant)
    }

    /// The update check, when the catalogs may be asked, then other Macs.
    @MainActor
    private func runLocalLane(on workspace: WorkspaceLaunch.Workspace, syncPass: @MainActor () async -> Void) async {
        if allowsNetworkCatalogs { await workspace.updates.checkIfDue() }
        await syncPass()
    }

    /// The assistant's runs, one after the other.
    @MainActor
    private func runAssistantLane(on workspace: WorkspaceLaunch.Workspace) async {
        let device = workspace.device
        let decided = consent
        await workspace.insights.runScheduledInsightsIfDue(
            consent: decided.allowing(device.effectiveAssistantRuns), managedClients: device.managedClients,
            current: { decided.allowing(device.effectiveAssistantRuns) })
        await workspace.setup.runScheduledReviewIfDue(consent: decided.allowing(device.effectiveAssistantRuns))
    }
}

extension WorkspaceLaunch.Workspace {
    /// Records which of the assistant's runs this Mac allows, the one way
    /// Let your assistant help, Settings › General and Home's notice record
    /// it, and stops the scheduled run the choice no longer allows: the
    /// weekly review once it is off, the deep dive or the keyword scan once
    /// theirs is.
    ///
    /// The run stops at once, as the switch flips, so nothing more leaves
    /// this Mac even if saving the choice fails and the switch is put back.
    /// The save is queued with this Mac's other device writes; the task it
    /// returns ends when it has settled.
    @MainActor @discardableResult
    func recordAssistantRuns(_ consent: AssistantRunConsent) -> Task<Void, Never> {
        if !consent.weeklyReview { setup.cancelScheduledReview() }
        insights.cancelScheduledRun(unlessAllowedBy: consent)
        let device = device
        return Task { await device.setAssistantRuns(consent) }
    }

    /// Turns one of the assistant's runs on or off, the others as they are:
    /// one switch of Let your assistant help or Settings › General.
    @MainActor @discardableResult
    func recordAssistantRun(_ run: AssistantRunCopy.Run, _ isOn: Bool) -> Task<Void, Never> {
        recordAssistantRuns(AssistantRunCopy.setting(run, isOn, in: device.effectiveAssistantRuns))
    }
}

extension AssistantRunConsent {
    /// The runs both this and `other` allow.
    fileprivate func allowing(_ other: AssistantRunConsent) -> AssistantRunConsent {
        AssistantRunConsent(
            weeklyReview: weeklyReview && other.weeklyReview, dailyDeepDive: dailyDeepDive && other.dailyDeepDive,
            localInsights: localInsights && other.localInsights)
    }
}

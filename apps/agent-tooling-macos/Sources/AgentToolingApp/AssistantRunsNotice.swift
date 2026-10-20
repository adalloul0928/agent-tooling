import AgentToolingCore
import SwiftUI

/// Asks legacy workspaces whether to keep their existing automatic assistant runs.
/// The answer is device-local. Any explicit consent choice dismisses the notice;
/// disabling a run also cancels scheduled work already underway.
struct AssistantRunsNotice: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.workspaceNavigate) private var navigate

    /// Whether Home shows the notice: the runs were never chosen on this Mac,
    /// and Claude Code or Codex is managed, so they really run (D27).
    static func shows(for device: WorkspaceDeviceSession) -> Bool {
        device.assistantRuns == nil && AssistantRunCopy.reviewer(managed: device.managedClients) != nil
    }

    var body: some View {
        let device = workspace.device
        if let reviewer = AssistantRunCopy.reviewer(managed: device.managedClients) {
            HStack(alignment: .top, spacing: Space.xl) {
                Image(systemName: "sparkles")
                    .font(.system(size: Size.heroSymbol, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: Size.tileLarge)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(AssistantRunCopy.noticeTitle)
                        .font(AgentFont.titleLarge)
                        .accessibilityAddTraits(.isHeader)
                    Text(AssistantRunCopy.noticeBody(reviewer: reviewer))
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                    settingsLine
                    if device.errorMessage == LaunchpadCopy.Footer.Failures.notRecorded {
                        SaveFailureLine(text: LaunchpadCopy.Footer.Failures.notRecorded)
                    }
                }
                Spacer(minLength: Space.xl)
                HStack(spacing: Space.md) {
                    Button(AssistantRunCopy.turnThemOff) { Self.turnOff(workspace) }
                        .buttonStyle(.glass)
                    Button(AssistantRunCopy.keepThemOn) { Self.keepOn(workspace) }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .padding(Space.xxl)
            .standardPanel()
            .accessibilityElement(children: .contain)
        }
    }

    /// "You can change this any time in Settings › General.", the place a
    /// link to it.
    private var settingsLine: some View {
        HStack(spacing: 0) {
            Text(AssistantRunCopy.changeAnyTimeLead).foregroundStyle(.secondary)
            Button(AssistantRunCopy.settingsPlace) { navigate(.settings) }
                .buttonStyle(.link)
            Text(AssistantRunCopy.changeAnyTimeEnd).foregroundStyle(.secondary)
        }
        .font(AgentFont.caption)
    }

    /// Keep them on: the runs the workspace always had, now as this Mac's
    /// choice.
    @discardableResult
    static func keepOn(_ workspace: WorkspaceLaunch.Workspace) -> Task<Void, Never> {
        workspace.recordAssistantRuns(.existingBehaviour)
    }

    /// Turn them off: every run off, and the scheduled ones already under way
    /// stopped.
    @discardableResult
    static func turnOff(_ workspace: WorkspaceLaunch.Workspace) -> Task<Void, Never> {
        workspace.recordAssistantRuns(.off)
    }
}

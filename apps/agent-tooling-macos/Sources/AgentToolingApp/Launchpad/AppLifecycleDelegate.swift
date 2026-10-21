import AppKit

/// Bridges AppKit launch, Dock reopen, and termination events. Stoppable setup
/// work receives a bounded cancellation grace; commits and other finishing writes
/// are awaited. A moved instance completes its disk-image cleanup after launch.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let launch = AppLaunchState.active, launch.context.afterMove != nil else { return }
        let context = launch.context
        Task { await MoveToApplications.finishAfterMove(context) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let launch = AppLaunchState.active else { return .terminateNow }
        let plan = launch.terminationPlan()
        let reply = Self.reply(for: plan)
        guard reply == .terminateLater else { return reply }
        Task {
            await launch.prepareToTerminate(plan)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return reply
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLaunchState.active?.reopen(hasVisibleWindows: flag) ?? true
    }

    /// Quit now when nothing is running; otherwise later, once it has
    /// stopped or finished.
    static func reply(for plan: AppLaunchState.TerminationPlan) -> NSApplication.TerminateReply {
        plan == .now ? .terminateNow : .terminateLater
    }
}

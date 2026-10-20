import AgentToolingCore
import AppKit
import SwiftUI

/// Hosts setup, unreadable-record, and opening states. Window events update the
/// launch coordinator; close requests confirm through the flow. Hand-off opens
/// the main window before fading this one. Links wait for the shell during setup.
struct SetupStageWindow: View {
    let launch: AppLaunchState
    @Environment(\.openWindow) private var openWindow
    @State private var presentation = SetupStagePresentation()

    var body: some View {
        let presentationID = launch.stagePresentationID
        return
            content
            // SwiftUI sizes a window to its content and the title bar's safe
            // area above it. The stage is 860 × 640 from the window's top
            // edge, so it claims its height less the title bar's, and draws up
            // under the title bar, where its drag band is.
            .frame(height: WindowSize.stage.height - Self.titleBarHeight, alignment: .bottom)
            .opacity(presentation.opacity(for: presentationID))
            // A fixed stage: never resized, zoomed or taken full screen.
            .windowResizeBehavior(.disabled)
            .windowFullScreenBehavior(.disabled)
            .background(
                WindowConfigurator(
                    role: .setup, onCloseButton: { launch.requestStageClose() },
                    onKeyChange: { launch.stageKeyChanged($0) },
                    onWindowClosed: { [weak launch] in launch?.stageDisappeared(presentationID: presentationID) })
            )
            .onAppear {
                launch.stageAppeared(openWindow: WindowOpener(openWindow))
            }
            .onChange(of: launch.flow?.workspace != nil) { _, committed in
                if committed, let workspace = launch.flow?.workspace { launch.didCommit(workspace) }
            }
            .onChange(of: launch.flow?.pendingHandOff) { _, section in
                if let section { handOff(to: section, presentationID: presentationID) }
            }
            .onChange(of: launch.flow?.quitRequested == true) { _, quit in
                if quit { launch.quit() }
            }
            .onChange(of: launch.stageHasNothingToShow, initial: true) { _, idle in
                if idle { handOverToMain() }
            }
            .onOpenURL { launch.queueLinkDuringSetup($0) }
    }

    @ViewBuilder private var content: some View {
        switch launch.phase {
        case .unreadable(let reason):
            LaunchpadUnreadableScreen(reason: reason, actions: launch.unreadableActions)
        case .setup, .opening, .ready, .failed:
            if let flow = launch.flow {
                LaunchpadStageView(flow: flow)
                    .id(ObjectIdentifier(flow))
            } else {
                StageOpening()
            }
        }
    }

    /// The flow's record is written; the launch flips to ready and opens the
    /// main window; then the stage fades and closes.
    private func handOff(to section: AppSection, presentationID: UUID) {
        guard launch.stagePresentationID == presentationID else { return }
        launch.handOff(to: section, openWindow: WindowOpener(openWindow))
        guard let fade = launch.environment.motion == .still ? nil : AgentMotion.quick else {
            launch.closeStage(presentationID: presentationID)
            return
        }
        withAnimation(fade) {
            presentation.leave(presentationID)
        } completion: {
            launch.closeStage(presentationID: presentationID)
        }
    }

    /// The height a titled window's title bar takes from its top on this
    /// system, as AppKit lays it out.
    @MainActor static let titleBarHeight: CGFloat = {
        let content = CGRect(origin: .zero, size: WindowSize.stage)
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: [.titled, .closable, .miniaturizable])
        return frame.height - content.height
    }()

    private func handOverToMain() {
        let presentationID = launch.stagePresentationID
        openWindow(id: AppWindow.main.sceneID)
        Task { @MainActor in
            guard launch.stagePresentationID == presentationID, launch.stageHasNothingToShow else { return }
            launch.closeStage(presentationID: presentationID)
        }
    }
}

/// SwiftUI may retain a closed window's root. Only the presentation that left
/// stays transparent; a new flow is visible without another appearance event.
struct SetupStagePresentation {
    private var leavingID: UUID?

    mutating func leave(_ presentationID: UUID) {
        leavingID = presentationID
    }

    func opacity(for presentationID: UUID) -> Double {
        leavingID == presentationID ? 0 : 1
    }
}

/// The stage while a first run left in progress opens its library to carry
/// on: the ground, the footer's strip, and a line saying what is happening.
private struct StageOpening: View {
    var body: some View {
        SetupStage {
            ProgressView(LaunchpadCopy.Welcome.openingWorkspace)
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } footer: {
            Color.clear
                .background(AgentTheme.fillSubtle)
                .overlay(alignment: .top) { Hairline() }
        } overlay: {
            EmptyView()
        }
    }
}

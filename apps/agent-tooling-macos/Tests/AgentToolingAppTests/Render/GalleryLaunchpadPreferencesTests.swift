import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Let your assistant help and How Agent Tooling behaves in the gallery, in
/// each state the fragments and their notes name, beside Settings › General's
/// rows for the same choices and Home's notice.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Launchpad preferences", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryLaunchpadPreferencesTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let assistantSource = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadAssistantScreen.swift"
    private static let behaveSource = "Sources/AgentToolingApp/Launchpad/Screens/LaunchpadBehaveScreen.swift"

    @Test func letYourAssistantHelp() async throws {
        for appearance in Self.both {
            for state in PreferencesGalleryState.assistantStates {
                let fixture = try await LaunchpadFixture()
                defer { fixture.remove() }
                let flow = try await state.flow(fixture)
                try galleryStageSnapshot(
                    PreferencesGalleryState.isolated(fixture.stage(flow), in: fixture.support),
                    screen: "S15 Let your assistant help",
                    state: state.name, appearance: appearance, source: Self.assistantSource)
            }
        }
    }

    @Test func howAgentToolingBehaves() async throws {
        for appearance in Self.both {
            for chosen in [AppAppearance.system, .dark] {
                let fixture = try await LaunchpadFixture()
                defer { fixture.remove() }
                let (flow, sample) = try await fixture.flow(at: .afterInstall)
                defer { sample.remove() }
                flow.advance()
                #expect(flow.step == .behave)
                try galleryStageSnapshot(
                    PreferencesGalleryState.isolated(fixture.stage(flow), in: fixture.support, appearance: chosen),
                    screen: "S16 How Agent Tooling behaves",
                    state: chosen == .system ? "defaults" : "Dark chosen", appearance: appearance, source: Self.behaveSource)
            }
        }
    }

    @Test func settingsGeneralAndTheNotice() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            await fixture.workspace.accounts.seed(PreferencesGalleryState.juniperSignIns)
            try galleryShellSnapshot(
                PreferencesGalleryState.isolated(
                    renderShell(.settings, fixture: fixture, size: GallerySize.standard), in: fixture.root),
                area: "Settings", screen: "Settings › General", state: "assistant card, before the choice",
                appearance: appearance, source: "Sources/AgentToolingApp/SettingsGeneralView.swift")
            let noAssistant = try await ShellRenderFixture()
            defer { noAssistant.remove() }
            await noAssistant.workspace.device.setEnabled(.claude, false)
            await noAssistant.workspace.device.setEnabled(.codex, false)
            try galleryShellSnapshot(
                PreferencesGalleryState.isolated(
                    renderShell(.settings, fixture: noAssistant, size: GallerySize.standard), in: noAssistant.root),
                area: "Settings", screen: "Settings › General", state: "assistant card, no assistant",
                appearance: appearance, source: "Sources/AgentToolingApp/SettingsGeneralView.swift")
            try gallerySnapshot(
                AssistantRunsNotice(workspace: fixture.workspace)
                    .padding(Space.xxxl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
                area: "Home", screen: "Home", state: "the assistant's runs notice", size: GallerySize.minimum,
                appearance: appearance, source: "Sources/AgentToolingApp/AssistantRunsNotice.swift")
        }
    }
}

/// One drawn state of Let your assistant help, and how to reach it.
@MainActor
struct PreferencesGalleryState {
    let name: String
    let flow: (LaunchpadFixture) async throws -> LaunchpadFlow

    static let weeklyOnly = AssistantRunConsent(weeklyReview: true, dailyDeepDive: false, localInsights: false)

    /// The states' names, in their order, for a test to take one state per
    /// case: a case builds one sample world, never five.
    nonisolated static let assistantStateNames = [
        "as it opens", "weekly review on", "Codex is the assistant", "API-key sign-in", "rerun, before the choice",
    ]

    /// The state called `name`.
    static func assistantState(named name: String) -> PreferencesGalleryState? {
        assistantStates.first { $0.name == name }
    }

    /// The states the fragment and its notes name: as it opens, the happy
    /// path with the weekly review on, Codex as the assistant, an API-key
    /// sign-in, and a rerun of a workspace made before the choice existed.
    static let assistantStates: [PreferencesGalleryState] = [
        PreferencesGalleryState(name: "as it opens") { fixture in
            try await fixture.flow(at: .afterInstall).flow
        },
        PreferencesGalleryState(name: "weekly review on") { fixture in
            let (flow, sample) = try await fixture.flow(at: .afterInstall)
            await sample.workspace.device.setAssistantRuns(weeklyOnly)
            return flow
        },
        PreferencesGalleryState(name: "Codex is the assistant") { fixture in
            let (flow, sample) = try await fixture.flow(at: .afterInstall)
            await sample.workspace.device.setEnabled(.claude, false)
            return flow
        },
        PreferencesGalleryState(name: "API-key sign-in") { fixture in
            let (flow, sample) = try await fixture.flow(at: .afterInstall)
            await sample.workspace.accounts.seed([
                AccountObservation(
                    provider: .claude, observedAt: ClientHomeFixture.now, clientVersion: "2.1.304",
                    signIn: AccountSignIn(method: .apiKey))
            ])
            await sample.workspace.device.setAssistantRuns(weeklyOnly)
            return flow
        },
        PreferencesGalleryState(name: "rerun, before the choice") { fixture in
            let workspace = try await legacyWorkspace(fixture)
            let flow = fixture.flow(.rerun, workspace: workspace)
            flow.go(to: .assistant)
            return flow
        },
    ]

    /// A workspace whose record has no assistant choice, as one made before
    /// the choice existed, with the sample world's sign-ins read.
    static func legacyWorkspace(_ fixture: LaunchpadFixture) async throws -> WorkspaceLaunch.Workspace {
        var preferences = fixture.seed.preferences
        preferences.assistantRuns = nil
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
        await workspace.library.refresh()
        await workspace.accounts.seed(juniperSignIns)
        return workspace
    }

    /// How Juniper's apps sign in, in the providers' order.
    static var juniperSignIns: [AccountObservation] {
        let signIns = LaunchpadFixture.signIns(for: .juniper)
        return AccountProvider.allCases.compactMap { signIns[$0] }
    }

    /// `view` reading and writing the app's own keys in a scratch suite, so
    /// a render neither reads nor leaves this Mac's choices; `appearance` is
    /// the choice it shows.
    ///
    /// The suite is a `ScratchDefaults` in `folder`, a fixture's own, so its
    /// file is kept there and goes when the fixture is removed.
    static func isolated(_ view: some View, in folder: URL, appearance: AppAppearance = .system) throws -> some View {
        let scratch = try ScratchDefaults("preferences", in: folder)
        if appearance != .system { scratch.defaults.set(appearance.rawValue, forKey: AppPreferenceKey.appearance) }
        return view.defaultAppStorage(scratch.defaults)
    }
}

import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Populates gallery screens through injected stubs. Checkup and Accounts use
/// their dedicated readers. Health is rendered separately with a scripted
/// session because shell launch wiring uses a real command runner.
extension ShellRenderFixture {
    /// Saves an assignment and leaves a request in the library, so Skills,
    /// Plugins and Connections all have real rows.
    func populateForGallery() async {
        await assignStandaloneSkill()
        try? await addRequestedPackage()
    }

    /// Refreshes every session whose screen reads from one, so the gallery
    /// captures drawn content instead of a first-frame loading state.
    func refreshForGallery() async {
        await workspace.library.refresh()
        await workspace.device.refresh()
        await workspace.settings.refresh()
        await workspace.marketplace.refresh()
        await workspace.projectDiscovery.refresh()
    }

    /// Reads the accounts the gallery scripted, so the Accounts screen captures
    /// its two signed-in accounts rather than its "Reading your accounts…"
    /// first frame. Only has contents to show when the fixture was built with
    /// `galleryAccountReader()`.
    func readAccountsForGallery() async {
        await workspace.accounts.read()
    }

    /// A reader that answers a Claude and a Codex account whose connectors,
    /// plugins, skills and apps are in mixed on, off and attention states, so
    /// the Accounts screen draws every row shape rather than a loading or empty
    /// frame. Pass it to `ShellRenderFixture(accountReader:)`.
    static func galleryAccountReader() -> StubAccountReader {
        StubAccountReader(answers: [
            .claude: AccountObservation(
                provider: .claude, clientVersion: "2.1.300",
                signIn: .init(
                    method: .subscription, email: "me@example.com",
                    organizationName: "Example", plan: "max"),
                items: [
                    .init(
                        provider: .claude, kind: .connector, key: "Gmail", name: "Gmail",
                        state: .init(tone: .ready, label: "Connected"), setting: .connector),
                    .init(
                        provider: .claude, kind: .connector, key: "Google Calendar",
                        name: "Google Calendar",
                        state: .init(tone: .attention, label: "Needs sign-in on claude.ai"),
                        setting: .connector),
                    .init(
                        provider: .claude, kind: .plugin, key: "design", name: "design",
                        state: .init(tone: .ready, label: "On"), setting: .plugin),
                    .init(
                        provider: .claude, kind: .plugin, key: "research", name: "research",
                        state: .init(tone: .off, label: "Off in Claude Code"), setting: .plugin),
                    .init(
                        provider: .claude, kind: .skill, key: "pdf", name: "pdf",
                        state: .init(tone: .ready, label: "Synced")),
                    .init(
                        provider: .claude, kind: .skill, key: "docx", name: "docx",
                        state: .init(tone: .off, label: "Off in Claude Code")),
                ],
                fileValues: [.init(.skillSync): .off], contentsRead: true),
            .chatGPT: AccountObservation(
                provider: .chatGPT, clientVersion: "0.162.1",
                signIn: .init(method: .subscription, plan: "plus"),
                items: [
                    .init(
                        provider: .chatGPT, kind: .app, key: "github", name: "GitHub",
                        state: .init(tone: .ready, label: "On"), setting: .app),
                    .init(
                        provider: .chatGPT, kind: .app, key: "linear", name: "Linear",
                        state: .init(tone: .off, label: "Off in Codex"), setting: .app),
                ],
                directoryCount: 12, contentsRead: true),
        ])
    }

    /// A kept checkup whose findings land in several buckets — a broken link to
    /// clean up, an unmanaged skill to decide on, and a missing plugin install
    /// — with a review on top, so the Checkup screen draws its grouped findings
    /// rather than "No checkup yet". Pass the result to
    /// `ShellRenderFixture(setupServices:)`.
    static func galleryCheckupServices() -> StubSetupServices {
        StubSetupServices(restored: setupCheckup(home: URL(filePath: "/Users/example")))
    }

    /// A Health session that has already checked, over a scripted listing with
    /// a needs-auth remote, a connected local, a failed plugin server and a
    /// claude.ai connector, so the Health screen draws every row shape rather
    /// than "Nothing has been checked yet".
    ///
    /// Health reads its listing through a command runner the launch wiring
    /// builds for real and does not let a test replace, so the gallery draws
    /// this scripted session through `HealthView` directly rather than through
    /// the shell. The listing mirrors the one `HealthSectionRenderTests` guards.
    func galleryHealthSession() async -> WorkspaceHealthSession {
        for client in ClientKind.allCases {
            await workspace.device.setEnabled(client, client == .claude)
        }
        let listing =
            "linear: https://mcp.linear.app/sse - ! Needs authentication\n"
            + "local: npx -y @scope/local - ✔ Connected\n"
            + "plugin:devtools:inspector: npx inspector - ✘ Failed to connect — connection refused\n"
            + "Gmail: claude.ai connector - ✘ Failed to connect — is Anthropic-hosted and doesn't support local OAuth"
        let session = WorkspaceHealthSession(
            device: workspace.device, homeRoot: home,
            runner: GalleryCommandRunner(output: listing),
            locate: { client, _ in
                URL(fileURLWithPath: "/opt/homebrew/bin/\(ClientExecutableLocator.executableName(for: client))")
            },
            openURL: { _ in })
        await session.check()
        return session
    }
}

/// A command runner that answers one scripted listing, so the gallery's Health
/// session reports a fixture rather than running a real client.
struct GalleryCommandRunner: CommandRunning {
    let output: String
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: output, standardError: "")
    }
}

import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The enrichment the gallery adds on top of the shared fixture: a library with
/// an assignment so the Skills and Plugins screens are past their onboarding
/// gate, a scanned device so the sidebar and Apps carry verdicts, and the
/// settings, marketplace, projects and insights sessions refreshed so their
/// screens draw rows rather than loading or empty states.
///
/// It only touches sessions the default fixture already wires with answering
/// stubs. Screens that need a differently-built fixture — Checkup with a kept
/// audit and Accounts with read contents — are built with the gallery helpers
/// below (`galleryCheckupServices`, `galleryAccountReader`) and refreshed with
/// `readAccountsForGallery`. Health reads its listing through a real command
/// runner the launch wiring does not let a test replace, so the shell Health
/// screen can only show its "nothing checked yet" state; its scripted listing
/// is left to a follow-up suite that draws `HealthView` directly.
extension ShellRenderFixture {
    /// Puts the library past onboarding and leaves a request in it, so Skills,
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
}

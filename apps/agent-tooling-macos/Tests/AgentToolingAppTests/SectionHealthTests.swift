import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// The sidebar dot is the app's quietest claim and its easiest one to get
/// wrong: a tick nobody earned is indistinguishable from one somebody did, and
/// a warning on a screen that was never inspected teaches people to ignore all
/// of them. These hold the rules that keep both from happening.
@Suite("Section verdicts")
struct SectionHealthTests {
    @Test("A section with nothing to report leaves its row undecorated")
    func nothingToReportMeansNoVerdict() {
        let quiet = SectionHealth()
        #expect(quiet.isQuiet)
        for section in AppSection.allCases {
            #expect(quiet[section] == nil, "\(section.rawValue)")
        }

        let noisy = SectionHealth(verdicts: [.skills: .attention])
        #expect(noisy[.skills] == .attention)
        #expect(noisy[.plugins] == nil)
        #expect(noisy[.overview] == nil)
    }

    @Test("No rule ever answers healthy")
    func healthyIsNeverAVerdict() {
        #expect(SectionHealth.skillsHealth([skill(states: [.healthy])]) == nil)
        #expect(SectionHealth.mcpHealth([server(states: [.healthy])]) == nil)
        #expect(SectionHealth.pluginsHealth([plugin(states: [.healthy])], sources: [], packages: []) == nil)
        #expect(SectionHealth.projectsHealth([]) == nil)
    }

    /// The old screen said this out loud and it still holds: a server nobody
    /// could reach is worse news than one still waiting, so unavailable
    /// outranks pending, and a reported fault outranks both.
    @Test("Connections rank attention over unavailable over pending")
    func connectionVerdictsAreRanked() {
        let pending = server(states: [.pending])
        let unreachable = server(states: [])
        let faulty = server(states: [.attention])

        #expect(SectionHealth.mcpHealth([pending]) == .pending)
        #expect(SectionHealth.mcpHealth([pending, unreachable]) == .unavailable)
        #expect(SectionHealth.mcpHealth([pending, unreachable, faulty]) == .attention)
    }

    /// An unowned skill is somebody else's. Reporting on it would be reporting
    /// on a client's own business as though this app had a say in it.
    @Test("Only skills this app owns can raise a verdict")
    func unownedSkillsAreNotJudged() {
        #expect(SectionHealth.skillsHealth([skill(owned: false, states: [.attention])]) == nil)
        #expect(SectionHealth.skillsHealth([skill(owned: true, states: [.attention])]) == .attention)
    }

    /// With no catalog and no sources there is nothing to compare against, so
    /// the row says "not checked" and the section stays silent rather than
    /// implying the library is current.
    @Test("Plugins report nothing until an update was actually checked")
    func pluginUpdatesNeedACatalog() {
        let plugins = [plugin(revision: "1.0.0")]

        #expect(SectionHealth.pluginsHealth(plugins, sources: [], packages: []) == nil)

        let verdicts = SectionHealth.pluginUpdateAvailability(plugins: plugins, sources: [], packages: [])
        #expect(verdicts.count == 1)
        #expect(verdicts[0].availability.isUnverified)
        #expect(verdicts[0].availability.isUpToDate == false)
    }

    /// A client that reported a fault outranks update news, which is only ever
    /// the calm clock: having a newer revision is news, not a fault.
    @Test("A reported fault outranks update news")
    func pluginFaultsOutrankUpdates() {
        #expect(SectionHealth.pluginsHealth([plugin(states: [.attention])], sources: [], packages: []) == .attention)
    }

    private func clients(_ states: [HealthState]) -> [ClientState] {
        zip(ClientKind.allCases, states).map { ClientState(client: $0, state: $1, detail: "Fixture") }
    }

    private func skill(owned: Bool = true, states: [HealthState] = []) -> Skill {
        Skill(
            id: "fixture-skill", name: "fixture-skill", displayName: "Fixture skill",
            summary: "A fixture.", bundle: "", scope: "user", owned: owned, triggers: [],
            negativeTrigger: "", files: [], clients: clients(states), validationCount: 0)
    }

    private func server(states: [HealthState] = []) -> MCPServer {
        MCPServer(
            id: "fixture-server", name: "Fixture server", summary: "A fixture.",
            endpoint: "https://example.invalid", transport: .http, authentication: "none",
            scope: "user", clients: clients(states))
    }

    private func plugin(revision: String = "1.0.0", states: [HealthState] = []) -> Plugin {
        Plugin(
            id: "fixture@source", name: "Fixture plugin", summary: "A fixture.",
            source: "fixture-source", scope: "user", revision: revision, skills: [], profiles: [],
            clients: clients(states), installed: true)
    }
}

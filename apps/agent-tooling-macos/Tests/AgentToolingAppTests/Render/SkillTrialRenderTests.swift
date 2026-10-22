import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The Apps rows in a skill's details offer to try the skill in each client
/// that has it. Drawing the pane must open nothing: the button reaches for
/// Terminal, and a render that did would open a window on somebody's Mac.
@Suite("Skill trial button renders")
@MainActor
struct SkillTrialRenderTests {
    @Test func theDetailPaneOffersATryButtonWhereTheSkillWasFoundAndOpensNothing() async throws {
        var claude = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true)
        claude.skillMetadata = [
            "standalone-skill": .init(path: "/Users/example/.claude/skills/standalone-skill", source: "Claude Code skill")
        ]
        let codex = ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true)
        let fixture = try await ShellRenderFixture(deviceObserver: StubDeviceObserver(observations: [claude, codex]))
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let inventory = SkillInventoryIndex(
            library: fixture.workspace.library.state?.library,
            snapshot: fixture.workspace.library.state?.snapshot,
            observations: fixture.workspace.device.observations,
            ownershipJSON: "{}")
        let skill = try #require(inventory.skills.first { $0.id == ShellRenderFixture.skill })
        #expect(inventory.observedClients[skill.id] == [.claude])
        let opening = RecordingSkillTrialOpening(available: [.claude, .codex])

        let withButton = try rasterize(detail(skill, fixture: fixture, inventory: inventory, opening: opening))
        try expectDrawn(detail(skill, fixture: fixture, inventory: inventory, opening: opening))
        // A Mac with no client tools draws the same rows with the buttons
        // disabled, so an enabled button has to have changed something.
        let without = try rasterize(
            detail(skill, fixture: fixture, inventory: inventory, opening: RecordingSkillTrialOpening(available: [])))

        #expect(withButton.tiffRepresentation != without.tiffRepresentation, "the try button changed nothing on screen")
        #expect(opening.requests.isEmpty, "drawing the pane opened Terminal")
    }

    @Test func tryingOpensTheSkillByItsDeclaredNameInThatClient() async throws {
        let opening = RecordingSkillTrialOpening(available: [.claude])

        let launch = try await opening.tryOut(skillName: "standalone-skill", in: .claude)

        #expect(opening.requests == [.init(client: .claude, skillName: "standalone-skill")])
        #expect(launch.arguments == ["/standalone-skill"])
        #expect(launch.commandLine == "claude /standalone-skill")
    }

    private func detail(
        _ skill: SkillEntry, fixture: ShellRenderFixture, inventory: SkillInventoryIndex,
        opening: RecordingSkillTrialOpening
    ) -> some View {
        SkillDetailView(
            skill: skill, workspace: fixture.workspace, content: fixture.contentSession(), inventory: inventory,
            availableClients: [.claude, .codex],
            onEditSource: {}, onAssign: {}, onExport: {}, onOpenPlugin: { _ in }
        )
        .environment(\.skillTrialOpening) { _ in opening }
        .frame(width: 720, height: 640)
    }
}

/// A Terminal that never opens. It answers with the launch it would have
/// prepared and remembers what it was asked, so a test can prove that a render
/// asked for nothing and a click asked for the right skill in the right client.
final class RecordingSkillTrialOpening: SkillTrialOpening, @unchecked Sendable {
    struct Request: Equatable {
        let client: ClientKind
        let skillName: String
    }

    private let lock = NSLock()
    private let available: Set<ClientKind>
    private var recorded: [Request] = []

    init(available: Set<ClientKind>) {
        self.available = available
    }

    var requests: [Request] { lock.withLock { recorded } }

    func canTry(in client: ClientKind) -> Bool {
        available.contains(client) && SkillTrialCommandShapes.isSupported(client)
    }

    func tryOut(skillName: String, in client: ClientKind) async throws -> SkillTrialLaunch {
        lock.withLock { recorded.append(Request(client: client, skillName: skillName)) }
        guard let arguments = SkillTrialCommandShapes.arguments(for: client, skillName: skillName) else {
            throw SkillTrialLaunchError.invalidSkillName(skillName)
        }
        let name = ClientExecutableLocator.executableName(for: client)
        return SkillTrialLaunch(
            client: client, skillName: skillName, executable: "/usr/local/bin/\(name)", arguments: arguments,
            scriptURL: URL(filePath: "/tmp/try-\(name).command"))
    }
}

import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Pins the wording for every deployment action in both plan views: the
/// install sheet, and a review (the setup stage's panel and the shared review
/// sheet). The two drew the same action in different words before this; the
/// shared extension is the single source, and these cases fail if either
/// drifts from it again.
@Suite("Deployment action phrasing")
struct WorkspaceDeploymentActionPhrasingTests {
    private func item(
        _ action: WorkspaceDeploymentAction,
        scope: ToolingScope = .user,
        surface: TargetSurface = .claudeCode
    ) -> WorkspaceDeploymentItem {
        WorkspaceDeploymentItem(
            artifactID: ArtifactID(),
            displayName: "Example",
            physicalDestinationID: WorkspaceObjectID(),
            surface: surface,
            scope: scope,
            logicalProjectID: nil,
            action: action,
            desiredEnabled: nil,
            reasons: [.manual]
        )
    }

    private let digest = ContentDigest(value: "a")

    @Test("The install sheet names the app once per action")
    func installSheetPhrases() {
        #expect(item(.installContent(digest: digest)).installActionText(app: "Claude Code") == "Install in Claude Code")
        #expect(
            item(.updateContent(from: nil, to: digest)).installActionText(app: "Claude Code")
                == "Replace what is there now in Claude Code")
        #expect(
            item(.updateContent(from: digest, to: digest)).installActionText(app: "Claude Code")
                == "Update to your approved version in Claude Code")
        #expect(
            item(.installNativePackage(route: .init(client: .claude, externalPluginID: "x")))
                .installActionText(app: "Claude Code") == "Ask Claude Code to install it")
        #expect(
            item(.configureManagedConnection(transport: .http)).installActionText(app: "Claude Code")
                == "Add the connection to Claude Code")
        #expect(
            item(.removeContent(installed: digest)).installActionText(app: "Claude Code")
                == "Remove the copy Agent Tooling installed in Claude Code")
    }

    @Test("A review names the item and its app in one phrase")
    func reviewPhrases() {
        #expect(item(.installContent(digest: digest)).reviewTitle(app: "Codex") == "Copy Example into Codex")
        #expect(item(.updateContent(from: nil, to: digest)).reviewTitle(app: "Codex") == "Replace Example in Codex")
        #expect(item(.updateContent(from: digest, to: digest)).reviewTitle(app: "Codex") == "Update Example in Codex")
        #expect(
            item(.installNativePackage(route: .init(client: .claude, externalPluginID: "x"))).reviewTitle(app: "Claude Code")
                == "Ask Claude Code to install Example")
        #expect(item(.configureManagedConnection(transport: .http)).reviewTitle(app: "Codex") == "Add Example to Codex")
        #expect(item(.removeContent(installed: digest)).reviewTitle(app: "Codex") == "Remove Example from Codex")
        #expect(item(.updateContent(from: nil, to: digest)).leftAloneTitle(app: "Codex") == "Example in Codex")
    }

    /// A step's app is named as a person knows it, whatever its surface says.
    @Test("A step names its app, never its surface")
    func aStepNamesItsApp() {
        #expect(item(.installContent(digest: digest), surface: .codexCLI).appName == "Codex")
        #expect(item(.installContent(digest: digest), surface: .claudeCode).appName == "Claude Code")
        for action in everyAction {
            let title = item(action, surface: .codexCLI).reviewTitle(app: item(action, surface: .codexCLI).appName)
            #expect(!title.contains("Codex CLI"), "\(title) names the surface")
            #expect(!title.hasSuffix("."), "\(title) ends a sentence")
        }
    }

    @Test("A removal keeps its reassurance as a note of its own; nothing else has one")
    func onlyARemovalHasANote() {
        #expect(item(.removeContent(installed: digest)).planActionNote == "Anything you changed is left alone.")
        for action in everyAction where !item(action).isRemoval {
            #expect(item(action).planActionNote == nil, "\(action) has a note")
        }
    }

    /// Every action the planner can produce, once.
    private var everyAction: [WorkspaceDeploymentAction] {
        [
            .installContent(digest: digest),
            .updateContent(from: nil, to: digest),
            .updateContent(from: digest, to: digest),
            .installNativePackage(route: .init(client: .claude, externalPluginID: "x")),
            .configureManagedConnection(transport: .http),
            .removeContent(installed: digest),
        ]
    }

    @Test("A removal says it removes, and keeps its reassurance, in both views")
    func oneRemovalWording() {
        let removal = item(.removeContent(installed: digest))
        #expect(removal.installActionText(app: "Codex").hasPrefix("Remove the copy Agent Tooling installed"))
        #expect(removal.reviewTitle(app: "Codex").hasPrefix("Remove"))
        #expect(removal.planActionNote == "Anything you changed is left alone.")
    }
}

import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Pins the wording for every deployment action in both plan views. The two
/// sheets drew the same action in different words before this; the shared
/// extension is the single source, and these cases fail if either sheet drifts
/// from it again.
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
        #expect(item(.removeContent(installed: digest)).installActionText(app: "Claude Code") == "Remove from Claude Code")
    }

    @Test("The plan sheet uses the same verbs with the place, not the app")
    func planSheetPhrases() {
        let account = "on this Mac"
        let project = "in this project"
        #expect(item(.installContent(digest: digest)).planActionClause(place: account) == "Install on this Mac")
        #expect(
            item(.updateContent(from: nil, to: digest)).planActionClause(place: account)
                == "Replace what is there now, on this Mac")
        #expect(
            item(.updateContent(from: digest, to: digest)).planActionClause(place: project)
                == "Update to your approved version, in this project")
        #expect(
            item(.installNativePackage(route: .init(client: .claude, externalPluginID: "x")))
                .planActionClause(place: account) == "Ask its app to install it, on this Mac")
        #expect(
            item(.configureManagedConnection(transport: .http)).planActionClause(place: account)
                == "Add the connection on this Mac")
        #expect(
            item(.removeContent(installed: digest)).planActionClause(place: account)
                == "Remove the copy this app installed, on this Mac. Anything you changed is left alone.")
    }
}

import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

/// These are the load-bearing tests. Every other test here checks that a
/// feature works; these check that a feature is *absent*, and absence is the
/// thing a well-meaning future change quietly removes.
///
/// If one of these fails, do not adjust the test. Read
/// `ExcludedCapabilities` and understand why the capability was excluded before
/// deciding the exclusion was wrong.
@Suite("Tool catalog exclusions")
struct ToolCatalogExclusionTests {
    @Test func catalogContainsNoApplyApproveDenyOrRunTool() {
        for tool in ToolCatalog.tools {
            #expect(
                ExcludedCapabilities.violatedToolNameFragment(in: tool.name) == nil,
                "'\(tool.name)' uses a fenced name. See ExcludedCapabilities for why."
            )
        }
    }

    @Test func namedForbiddenToolsAreAbsent() {
        let names = Set(ToolCatalog.tools.map(\.name))
        let forbidden = [
            "apply", "apply_plan", "approve", "approve_plan", "approve_request", "deny", "deny_request", "reject_request",
            "confirm", "confirm_plan", "execute", "execute_plan", "run", "run_command", "shell", "create_mcp", "update_mcp",
            "delete_mcp", "create_skill", "delete_skill", "create_hook", "get_secret", "read_secret", "set_allowlist",
            "register_server", "edit_redaction_patterns",
        ]
        for name in forbidden {
            #expect(!names.contains(name), "'\(name)' must never be a tool on this server.")
        }
    }

    @Test func noToolDeclaresAHomeOrWorkspaceParameter() {
        for name in ToolCatalog.declaredParameterNames() {
            #expect(
                ExcludedCapabilities.violatedParameterNameFragment(in: name) == nil,
                "The parameter '\(name)' reintroduces a fenced input. --home and --workspace are a path-confinement bypass."
            )
        }
    }

    @Test func everyToolIsInOneOfExactlyTwoTiers() {
        #expect(ToolCatalog.tools.count == 14)
        #expect(ToolCatalog.readOnlyTools.count == 9)
        #expect(ToolCatalog.reviewQueueTools.count == 5)
        #expect(ToolCatalog.readOnlyTools.allSatisfy { $0.tier == .readOnly })
        #expect(ToolCatalog.reviewQueueTools.allSatisfy { $0.tier == .queuesReview })
        #expect(ToolTier.allCases.count == 2)
    }

    @Test func toolNamesAreUniqueAndSchemasRefuseUndeclaredArguments() throws {
        #expect(Set(ToolCatalog.tools.map(\.name)).count == ToolCatalog.tools.count)
        for tool in ToolCatalog.tools {
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("\(tool.name) has no object schema.")
                continue
            }
            #expect(schema["additionalProperties"] == .bool(false), "\(tool.name) must refuse undeclared arguments.")
        }
    }

    @Test func readOnlyToolsAreAnnotatedReadOnlyAndNothingIsDestructive() throws {
        for tool in ToolCatalog.tools {
            guard case .object(let descriptor) = tool.descriptor,
                case .object(let annotations)? = descriptor["annotations"]
            else {
                Issue.record("\(tool.name) has no annotations.")
                continue
            }
            #expect(annotations["readOnlyHint"] == .bool(tool.tier == .readOnly))
            #expect(annotations["destructiveHint"] == .bool(false))
        }
    }

    @Test func serverDeclaresToolsAndNotElicitation() throws {
        let harness = try MCPTestHarness()
        let result = try harness.initialize()
        guard case .object(let capabilities)? = result["capabilities"] else {
            Issue.record("The handshake declared no capabilities.")
            return
        }
        #expect(capabilities["tools"] != nil)
        // Elicitation renders a dialog in the caller's own client from
        // server-supplied text. That can collect a missing project root; it can
        // never be where a person approves a change.
        #expect(capabilities["elicitation"] == nil)
        #expect(capabilities["sampling"] == nil)
    }

    @Test func theBinaryAcceptsNoConfigurationOnTheCommandLine() {
        // --home and --workspace exist on the CLI helper for tests. Reachable
        // from an MCP client they would let a caller aim the server at a
        // workspace it wrote itself.
        #expect(!ExcludedCapabilities.permittedArguments.contains("--home"))
        #expect(!ExcludedCapabilities.permittedArguments.contains("--workspace"))
        #expect(ExcludedCapabilities.permittedArguments == ["--help", "-h", "--version"])
    }
}

import AgentToolingCore
import Darwin
import Foundation

/// `agent-tooling-mcp` — the stdio MCP server that ships inside the Agent
/// Tooling app bundle, beside the `agent-tooling` CLI helper.
///
/// It takes no arguments. That is deliberate: the CLI helper accepts `--home`
/// and `--workspace` so tests can point it at a scratch directory, and either
/// flag reachable from an MCP client would be a path-confinement bypass — a
/// caller could aim the server at a workspace it wrote itself and then read or
/// queue against state no person had ever seen. This binary resolves the one
/// real workspace and refuses everything else on the command line.
@main
struct AgentToolingMCPMain {
    static func main() {
        // A client that closes the pipe mid-write should end the session, not
        // kill the process with a signal.
        signal(SIGPIPE, SIG_IGN)

        let arguments = Array(CommandLine.arguments.dropFirst())
        for argument in arguments where !ExcludedCapabilities.permittedArguments.contains(argument) {
            writeError(
                """
                agent-tooling-mcp: unexpected argument '\(argument)'.

                This server takes no configuration on the command line. In particular there is no --home or --workspace override; \
                see ExcludedCapabilities in the source for why.
                """
            )
            Darwin.exit(64)
        }
        if arguments.contains("--version") {
            print(ToolCatalog.serverVersion)
            return
        }
        if !arguments.isEmpty {
            printUsage()
            return
        }

        do {
            let store = try WorkspaceStore()
            let service = ToolingMCPService(store: store)
            // Nothing may be written to standard output except protocol
            // frames; a stray log line would corrupt the stream. Diagnostics
            // go to standard error.
            Darwin.exit(service.run(transport: StdioTransport()))
        } catch {
            writeError("agent-tooling-mcp: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            agent-tooling-mcp — Agent Tooling's local MCP server.

            Usage: agent-tooling-mcp

            Speaks MCP over stdio (JSON-RPC 2.0, one message per line) on the pipe its parent provides. There is no listening \
            port: any local process can reach a port, and DNS rebinding can reach one from a web page, so the transport is the \
            pipe and nothing else.

            Tools fall into two tiers:

              read-only      search_inventory, get_component, get_client_status, list_receipts, get_receipt,
                             list_pending_requests, get_request_status, open_review_screen
              queues-review  request_add_mcp_server, request_create_skill, request_install_skill,
                             request_install_plugin, request_remove_component

            A queued request changes nothing. It adds one row for a person to review in the Agent Tooling app, which is the only \
            place a change can be approved. There is no tool that applies, approves or denies, and no argument that relocates the \
            workspace or the home directory.

            Register it with a client by pointing that client at this executable inside the app bundle:

              Agent Tooling.app/Contents/Helpers/agent-tooling-mcp
            """)
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }
}

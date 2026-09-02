import Foundation

// MARK: - Why this server is deliberately incomplete
//
// Read this before adding a tool. The omissions below are the security model,
// not an unfinished backlog.
//
// 1. There is no `apply`, `approve`, `deny`, `confirm`, or `execute` tool, and
//    there never will be one.
//
//    `agent-tooling apply --confirm <planID> --digest <sha256>` looks like a
//    consent check. It is not. The digest is a plain SHA-256 over the plan's
//    own encoded bytes, so it proves only that the plan being executed is
//    byte-identical to the plan someone read. It is content integrity. Anyone
//    holding a plan can compute a valid digest for that plan in one line of
//    code. That is safe today because the only caller is the app's own review
//    sheet, where a human has actually looked at the diff.
//
//    Exposing `apply` over MCP would hand a prompt-injected agent a
//    self-approval primitive: build a plan, hash it, approve its own work, and
//    the "confirmation" would pass every check the code performs. The same is
//    true of any tool that merely *records* an approval, because the recording
//    would be made by the caller rather than by the person. Research cited by
//    OWASP found tool poisoning succeeds around 84% of the time once
//    auto-approval is in play; a self-approval primitive is auto-approval with
//    extra steps.
//
//    Consent lives in exactly one place: the app's review sheet, where a human
//    sees the real redacted command next to the file it changes. This server
//    can put a bounded row in front of that human. It cannot answer for them.
//
// 2. This server never builds an `OperationPlan`. Tier 2 tools append one
//    bounded request row and return a deep link. The plan is composed in-app,
//    from the app's own state, when the person opens that link. Building the
//    plan here would move the reviewed artifact under the caller's control.
//
// 3. There is no `--home` or `--workspace` override, and no tool parameter that
//    relocates the workspace or the home directory. Those flags exist on the
//    CLI for tests. Over MCP they would be a path-confinement bypass: a caller
//    could point the server at a workspace it had written itself, then read or
//    queue against state no human ever saw. The server always resolves the one
//    real workspace, and it accepts no argv at all beyond `--help`/`--version`.
//
// 4. There is no generic `run_command`, `exec`, shell, or file-write tool, and
//    this target spawns no subprocess of any kind. `get_client_status` reports
//    the observations the app persisted during its last setup check rather than
//    shelling out to the client CLIs, so there is no process-execution
//    primitive in this address space to borrow.
//
// 5. No tool returns a secret value. Secret *reference names* are returned;
//    endpoints, commands, environment values, and tokens are not. Every string
//    leaf of every response is swept by `ResponseRedaction` before it leaves
//    the process, so a home directory cannot land in an agent transcript.
//
// 6. No tool edits the operation allowlist, the redaction patterns, this
//    server's own registration, or any other policy input. A tool that can
//    weaken the review path is equivalent to a tool that can skip it.
//
// 7. The MCP elicitation capability is not declared. Elicitation renders a
//    dialog inside the *agent's* client from text this server supplies, which
//    makes it a fine way to collect a missing project root and a terrible way
//    to collect consent: the person would be approving a sentence written by
//    the server, not the redacted command written next to the file it changes.
//    Rather than implement it and police the boundary at runtime, the
//    capability is simply absent. A missing parameter is reported back as a
//    normal tool error naming the parameter, and the agent asks in its own
//    words.
//
// `ExcludedCapabilities` below turns those rules into assertions. The test
// suite walks the whole catalog against them, so a tool that reintroduces any
// of this fails the build rather than shipping.

/// Machine-checkable form of the exclusions documented above.
enum ExcludedCapabilities {
    /// Case-insensitive fragments that may not appear in a tool name. These
    /// cover the self-approval primitive (1), plan execution (2), arbitrary
    /// execution (4), secret disclosure (5), and policy edits (6).
    ///
    /// The fence is deliberately wider than the named exclusions. `run` and
    /// `command` reject `get_runtime_status` as collateral, and that is the
    /// intent: a contributor who wants a name in this space has to come back
    /// here and read why it is fenced before renaming around it. `install` is
    /// absent on purpose, because `request_install_skill` only queues a row for
    /// a human and installs nothing.
    static let forbiddenToolNameFragments: [String] = [
        "allowlist",
        "apply",
        "approval",
        "approve",
        "authorize",
        "command",
        "confirm",
        "consent",
        "credential",
        "delete",
        "deny",
        "digest",
        "eval",
        "exec",
        "execute",
        "invoke",
        "password",
        "patch",
        "policy",
        "redaction",
        "register",
        "reject",
        "run",
        "secret",
        "shell",
        "token",
        "write",
    ]

    /// Case-insensitive fragments that may not appear in a tool parameter name.
    /// `home` and `workspace` are the path-confinement bypass from (3).
    static let forbiddenParameterNameFragments: [String] = [
        "allowlist",
        "approve",
        "confirm",
        "credential",
        "digest",
        "home",
        "password",
        "planid",
        "plan_id",
        "redaction",
        "secret",
        "token",
        "workspace",
    ]

    /// Argv this executable will accept. Anything else is refused, so no caller
    /// can relocate the workspace or the home directory through the process
    /// arguments either.
    static let permittedArguments: Set<String> = ["--help", "-h", "--version"]

    static func violatedToolNameFragment(in name: String) -> String? {
        let lowered = name.lowercased()
        return forbiddenToolNameFragments.first { lowered.contains($0) }
    }

    static func violatedParameterNameFragment(in name: String) -> String? {
        let lowered = name.lowercased()
        return forbiddenParameterNameFragments.first { lowered.contains($0) }
    }
}

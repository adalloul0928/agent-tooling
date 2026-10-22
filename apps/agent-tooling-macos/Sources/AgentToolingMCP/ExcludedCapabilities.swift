import Foundation

// MARK: - MCP security boundary
//
// 1. Consent and execution exist only in the app's review sheet. MCP cannot
//    apply, approve, deny or execute plans. A plan hash proves integrity, not
//    consent: letting the caller provide one would permit self-approval.
// 2. Queue tools append one bounded request and return a link. The app builds
//    the plan from its own state after the person opens that link.
// 3. Home/workspace overrides are prohibited, including through argv. They
//    would let callers substitute a workspace they control. Only help and
//    version arguments are accepted.
// 4. This target starts no subprocesses and exposes no generic command or
//    file-write tool. Client status comes from persisted observations.
// 5. Responses expose secret reference names, never values, endpoints or
//    commands. ResponseRedaction checks every string leaf, including paths.
// 6. Tools cannot alter policy, allowlists, redaction or MCP registration.
// 7. Elicitation is absent: a server-written dialog cannot replace the app's
//    display of the exact operation. Missing parameters produce normal errors.
//
// Catalog tests enforce these exclusions. Changes require revisiting this
// boundary, not renaming a prohibited capability to evade the checks.

/// Machine-checkable form of the exclusions documented above.
enum ExcludedCapabilities {
    /// Conservative name fence for self-approval, execution, disclosure and
    /// policy edits. `install` is allowed because request tools only queue work.
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

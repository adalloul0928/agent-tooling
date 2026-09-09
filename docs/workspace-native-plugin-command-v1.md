# Workspace native plugin command planning v1

`WorkspaceNativePluginCommandPlanning` is a pure admission layer for one
native plugin install command. It performs no process execution, filesystem
write, marketplace refresh, update, removal, enablement change, authentication,
or post-install verification.

The planner requires three independent facts:

- Portable ownership identifies a root `nativePlugin` artifact, its
  `nativeOwned` authority, and the exact `NativePackageRoute` for the consuming
  client. Ownership alone cannot create an install command.
- A complete current-device assignment resolution supplies the selected
  physical target and exact supported adapter capability. The planner reruns
  `WorkspaceAssignmentResolver` over every assignment for the artifact so a
  caller cannot omit a conflicting contribution.
- A `NativeInstall` supplied from a reviewed current marketplace must exactly
  match the client, user scope, executable, and arguments derived from the
  native route. Persisted `DeviceMarketplaceSnapshot` metadata is not fresh
  install authorization.

The v1 command set is intentionally finite:

| Client | Scope | Executable and arguments |
| --- | --- | --- |
| Claude Code | user | `claude plugin install <id> --scope user` |
| Codex CLI | user | `codex plugin add <id>` |

Gemini extension linking, project scopes, update, and removal are outside this
contract. Removal has no portable assignment intent because v1 assignments
require desired presence. Update requires current installed-state evidence.
Neither operation may be inferred from an install assignment.

An install command expresses presence only. Explicit `desiredEnabled` values
are rejected because these commands do not provide a reviewed enable/disable
operation. Managed-policy blocks fail closed; an unresolved blocked-plugin
reference also prevents a command until the policy can be resolved. Native
package children are never installed independently.

The returned `WorkspaceNativePluginCommandPlan` contains the admitted command
for later review. It does not mean that installation succeeded or that bundled
skills, hooks, MCP servers, accounts, or tools are active. A later executor must
retain confirmation, operation journaling, cancellation, rescan, and receipt
requirements.

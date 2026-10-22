# Standalone skill assignment migration

This packet connects portable configuration resolution to a one-time standalone
skill assignment preview and the existing native CLI destination routes. It does
not switch the application store or install a skill.

## Configuration intent

`WorkspaceConfigurationResolver` validates the portable graph before resolving a
personal configuration. Requirements and collection items form a union through
the ancestor chain. Unresolved artifact references stay visible as unresolved
references. Inherited checks keep ancestor-first order. The nearest non-nil
target binding list replaces the complete ancestor list; an empty list is an
explicit choice of no targets. Optional enabled values remain optional.

Device inventory and app visibility do not remove portable intent. Policy
templates cannot become active personal configurations through this API. Invalid
parents, collections, cycles and duplicate identities are rejected by the graph
validator. Legacy duplicate check IDs within one configuration remain migration
blockers, because the portable contract requires unique check IDs there.

## One-time conversion

`WorkspaceSkillAssignmentMigration.preview` consumes an assembled migration
candidate. It uses the candidate's legacy snapshot only to identify the old
owned standalone sync behavior. It does not reconstruct desired state from
`DeviceInventoryState`, which remains historical display data.

- A selected configuration with explicit bindings deploys only required skills
  whose binding says enabled `true`, intersected with enabled apps.
- With no explicit bindings in the inheritance chain, the old owned skill's app
  list supplies a one-time fallback, even if that skill was not named in the
  active configuration. This becomes explicit manual contributions.
- Skill scope stays with the skill. A project configuration does not turn a
  user-scoped skill into a project installation. Project-scoped skills require
  an explicit logical project mapping and matching device root.
- The reviewed artifact must be a standalone central personal or upstream
  skill. Package children, native ownership and unsupported scopes produce
  review issues rather than extracted copies. Non-owned repository-linked
  updates continue through their separate source update route.
- Deployment names preserve existing installation folder names separately from
  display and declared names. They are validated as individual path components.
- Contributions target the current device. Their UUIDv8 identities use SHA-256
  over length-framed workspace, device, artifact, surface, scope, project and
  configuration identity, under a versioned namespace. Repeated previews are
  stable. An identical already-present contribution is a no-op; changed intent
  under that identity requires review.

The result is a proposal, not an executable plan. Partial proposals with issues
must not be treated as a successful migration. Native plugin installation and
managed MCP migration have separate contracts; this API does not claim parity
for those operations.

## Native target evidence

`NativeSkillDestination` is the shared pure path router used by the existing
`WorkspaceLibrary.installPlan` and new device capture:

| Client | User directory | Project directory |
| --- | --- | --- |
| Claude Code | `<home>/.claude/skills` | `<project>/.claude/skills` |
| Codex CLI | `<home>/.agents/skills` | `<project>/.agents/skills` |
| Gemini CLI | `<home>/.gemini/skills` | `<project>/.gemini/skills` |

`WorkspaceSkillTargetCapture` runs directory resolution on a utility task.
Existing roots must be directories. Project leaf symlinks are rejected, matching
the legacy planner. Existing skill-directory aliases are resolved to their
canonical physical path using an open directory descriptor. For an absent
directory, capture resolves the nearest existing ancestor and appends the
missing path components without creating them. Files and dangling links block
capture. Repeated root/directory checks detect ordinary replacement during the
capture; this is not filesystem snapshot isolation.

Physical identities include the device and canonical directory, rather than the
app label. Two CLI selectors that share one folder therefore reach one physical
requirement in `WorkspaceAssignmentResolver`, preserving both reasons. All
paths and physical IDs remain device-local evidence. Desktop and cloud routes
are unsupported by this capture adapter until separately validated.

An observation's version is carried forward, but generic capability flags do not
become skill support. The assignment resolver still requires explicit evidence
matching the client version, adapter contract, component and scope, plus content
evidence. Capture does not probe or start a native client.

## Remaining integration

Before cutover, the reviewed migration must persist assignment proposals and
deployment names together with the checkpoint-bound candidate, verify current
source/destination evidence, and record a recoverable migration receipt.
Destination writes still need staged composition, baseline checks and the
existing reviewed executor. The portable read model, UI/CLI entry points,
packaged migration pilot, native invocation and two-Mac acceptance gates remain
separate work. The progress ledger records test evidence for this packet.

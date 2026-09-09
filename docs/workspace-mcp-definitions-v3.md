# Managed MCP definitions, schema 3

This additive contract preserves existing agent-managed MCP declarations without
creating a package copy or taking ownership of native plugin children. The live
app still uses `WorkspaceSnapshot`; neither a preview nor a metadata-store test
changes native client configuration.

## Definition and device setup

Schema 3 adds `PortableWorkspaceDocument.mcpDefinitions` and
`DeviceWorkspaceState.mcpBindings`. Both are explicit arrays in schema 3 and
absent in schemas 1 and 2. Older document bytes and digest preimages retain their
original meaning. Reader/writer versions must match the document's schema;
unknown fields and mixed enum payloads remain errors in the canonical codec.

Each portable definition identifies exactly one standalone, central-personal
MCP artifact with no content digest. The definition contains either:

- `remoteHTTPS`: an explicitly reviewed, credential-free HTTPS URL with a DNS
  name. IP literals, single-label names and recognized local names use device
  bindings. A DNS name can still resolve privately; this is not a public-host or
  reachability assertion.
- `deviceBound`: a declared HTTP or stdio transport, resolved on each device.

A device binding holds the matching HTTP URL or executable/argument vector,
credential requirement names, authentication requirement and optional workspace
root. It cannot override a portable remote URL. Argument vectors preserve spaces
and empty arguments; validation does not invoke a shell. Known credential-value
patterns, inline credential flags, URL credentials, queries and fragments are
rejected. Pattern checks cannot recognize every possible secret.

Authentication requirements are `none`, `oauth`, `apiKey`, `doppler` or
`environment`. They describe setup intent and never assert an authenticated
account or available credentials. Named requirements accept bounded identifiers
containing letters, digits, underscore, dot and hyphen, starting with a letter
or underscore. Other legacy names require review; values are never copied.

All commands, credential names, authentication setup and local roots stay outside
the portable document and its digest. A newly enrolled device may lack a binding;
assignment resolution must report the missing setup rather than invent it.
Native/plugin MCP children and MCP files in complete upstream packages retain
their package ownership and existing content contracts.

Portable schema 4 additionally permits a native MCP declaration without its own
file path. It must have a nonempty declared name and a native-owned plugin
parent, with no content digest or child install routes. Inventory retains the
exact observed MCP identity and parent relationship. Missing or conflicting
parent membership blocks migration. No `PortableMCPDefinitionRecord` or central
content is created for this case; only the whole parent may receive an
assignment. Schemas 1–3 still require paths on all children, and old document
bytes round-trip unchanged. Device schema remains 4.

## Migration

`WorkspaceManagedMCPMigrationResolution` is explicit evidence supplied alongside
the existing artifact resolution. It retains the reserved MCP identity and must
match the legacy endpoint or parsed argv, transport, credential names and one
recognized authentication requirement exactly. Unsupported authentication and
scope values remain blockers.

Every legacy client receives exactly one presence contribution for its existing
CLI surface on the current device. Health and installed flags do not infer
enabled intent. A missing client, extra client, all-device expansion or invented
enablement blocks migration. Existing editable scopes are This Mac, Project,
This project only and Workspace.

Project scopes require a reviewed logical-project identity plus the exact
device root. Repeated references to the same project share one identity;
contradictory identities or roots are rejected. The caller retains reviewed
project mappings between previews and passes them back through
`preservingMCPProjectMappings`; changed IDs for an existing root are rejected.
Caller-supplied contribution IDs likewise remain part of the retained review
input. Workspace scope retains its
root in the MCP device binding and has no portable logical-project ID. Project
mapping outputs are review evidence, not durable enrollment; the full migration
assembler must retain them when composing configuration/device state.

The preview validates the actual artifact, source, project, assignment and MCP
graph. It retains the original typed snapshot locally and returns actionable
definition intent separately. That does not satisfy the remaining D2 raw-store
checkpoint, old/new destination parity, atomic cutover or rollback gates.

## Assignment boundary

A managed MCP definition uses a distinct assignment strategy rather than the
complete-file content gate. The resolver requires its typed definition and any
necessary device binding, consistent transport evidence, a captured target and
exact client-version/adapter/scope capability evidence. Workspace destinations
also require the device root. Returned requirements still need a reviewed
native operation plan; this module starts no servers, authenticates no accounts
and writes no client files.

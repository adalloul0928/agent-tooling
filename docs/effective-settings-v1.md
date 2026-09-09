# Effective native settings v1

Status: the resolver and two versioned vendor adapters are implemented and
fixture-tested. No file reader, inspector UI or editor exists yet, and no
adapter has been checked against a live installed client, so this does not
establish effective-settings coverage for any real setup.

## Contract

`EffectiveConfigurationResolver.resolve` explains what a native client will use
and why. It reads nothing and writes nothing: the caller supplies already-parsed
layers, and the result is an explanation, not a plan.

Precedence and per-setting merge rules come from a versioned `ConfigurationAdapter`
per vendor. There is deliberately no shared "project beats user" rule: adding a
client means adding an adapter with its own tested precedence.

Each row reports the effective value, the layer and file that defined it, every
contributing layer in precedence order with which of them are overridden, the
merge rule, whether a new session is required, and the highest-precedence layer
this app could write. A value fixed by policy or by a session override is
reported as constrained: a writable file underneath it cannot change what the
client uses, so no editor is offered there.

Settings whose lists combine — hooks, permission lists, MCP server sets — are
merged highest precedence first, and no contribution is marked overridden,
because every layer applies.

A layer the installed version does not read stays visible and is listed as
inactive; it never contributes to an effective value. Keys the build does not
interpret are reported with the layer they came from and are never presented as
effective, never dropped and never rewritten.

When session or command-line overrides cannot be observed, the result says so
rather than presenting local files as final: "Expected from local configuration;
session overrides unknown."

## Version-specific facts encoded so far

| Vendor | Fact | Encoding |
| --- | --- | --- |
| Claude Code | Managed policy constrains lower layers | `managedPolicy` is highest precedence and never writable |
| Claude Code | Hook and permission lists combine | `combineList` for `hooks`, `permissions.allow`, `permissions.deny` |
| Codex | No managed-policy layer and no project settings file | `managedPolicy` absent from precedence; a file there is reported inactive |
| Codex | Named profiles moved to separate `<name>.config.toml` files in 0.134.0 | `usesSeparateProfileFiles`, from the installed version; an unknown version claims neither layout |

## Reading real files

`ConfigurationLayerReader` turns files on disk into layers. It only reads:
nothing is rewritten, reformatted or normalized. A file that is absent produces
no layer, while a file that exists but cannot be parsed is an error — treating a
broken file as empty would present a partial picture as complete. Files above
1 MB are refused rather than read.

Claude Code's user, project, local-project and managed-policy files are read as
JSON. Managed policy is never writable. `permissions.allow` and `permissions.deny`
are interpreted because they are documented named lists; any other key under
`permissions`, and any unknown top-level key, is recorded as unrecognized so it
stays visible without this build claiming to understand it. Nested structures
become opaque rather than being flattened into claims about their contents.

Codex's `config.toml` is read for top-level scalar assignments; a table is
recorded by name only. A named profile file is read only when the installed
release is one that keeps profiles in separate files, so neither documented
layout is assumed.

## Inspecting and editing

An **App settings** destination shows what each installed app will use on this
Mac, optionally for one confirmed project, in the person's terms rather than as
file paths. Reading runs off the main actor and writes nothing. The installed
version comes from what this device observed; a version never observed claims
nothing.

`ConfigurationEditor` writes one setting into one JSON file and then verifies
the change actually won. Everything else in the file survives: unknown keys and
vendor-only nesting are the person's, not ours. A file that changed since it was
reviewed is never overwritten. A backup is written first, and the file is re-read
and resolved again afterwards — a write that does not produce the intended
effective value is reported, never called success. A value fixed by a higher
layer offers no edit at all, a setting this build has no definition for cannot be
written, and a value this build only ever read as opaque is never written back.

Codex's TOML is deliberately not editable here: it keeps comments and formatting
this build cannot reproduce faithfully, and rewriting someone's file to satisfy a
parser would be the wrong trade.

An MCP tool, `get_effective_settings`, reports the same explanation to an agent.
It reads the agent's own files and writes nothing; settings this build does not
interpret are listed separately and never presented as effective.

## Not yet implemented

Project trust gating, Claude Desktop MCP discovery, an editing UI, hooks/agents/
instructions views, and the dated compatibility register with upstream
schema-change detection all remain open. Gemini has no adapter; its current TOML
discovery must not be presented as effective-settings support. No adapter has
been checked against a live installed client.

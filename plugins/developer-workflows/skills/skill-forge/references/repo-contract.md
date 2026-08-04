# Repository contract

What the static validation script actually enforces, and the failure each rule
produces. Everything here runs in CI on every pull request, so a clean local run
is a good predictor of a green PR.

Run it from the repository root. It needs a JSON processor, Python 3, ripgrep,
and the Agent Skills reference validator on `PATH`.

## Skill rules

| Rule | Failure if broken |
|---|---|
| Every `SKILL.md` under a bundle passes the Agent Skills validator | Validator error naming the skill directory |
| `name` frontmatter equals the directory name | Validator error |
| Frontmatter carries only the standard fields | Validator error |
| No hard-coded client installation or configuration path anywhere under the bundles | `Found a hard-coded Claude or Codex installation path.` |
| No symlink resolving outside its own bundle | `Plugin symlink escapes its package` |
| Bundled `scripts/*.sh` are syntactically valid shell | `bash -n` error |
| Bundled Python compiles | Compilation error |

The hard-coded-path scan is a regular expression over the whole bundle tree. It
catches a home-relative or absolute reference to a client's dot-directory, and
absolute home paths that descend into a plugins or skills directory. It does not
care whether the mention is in prose or in code — a path in a documentation
table fails the build exactly like one in a script.

Write "the client's user-scoped skills directory" instead. This is not
pedantry: the same instruction has to be correct for two clients whose install
locations differ, and one of them does not use the directory you would guess.

## Bundle rules

Required for every bundle, checked per catalog entry:

```
plugins/<bundle>/
  .claude-plugin/plugin.json     required
  .codex-plugin/plugin.json      required
  skills/<skill>/SKILL.md        the one physical core
  .mcp.json                      only if the bundle provides MCP servers
```

| Rule | Failure |
|---|---|
| Both adapter manifests exist | `Missing adapter manifest` |
| Each manifest's `name` equals its catalog entry name | `Adapter name mismatch` |
| Neither manifest declares `version` | `Plugin manifest must omit version under Git-revision policy` |
| Both manifests declare the same MCP source, or neither does | `Claude and Codex MCP declarations differ` |
| A declared MCP path is bundle-relative, resolves inside the bundle, and holds at least one server | `Invalid MCP declaration` / `must contain at least one server` |

The Claude manifest is minimal — name, description, author. The Codex manifest
adds the skills directory pointer and an `interface` block with display name,
short and long description, developer name, category, capabilities, and default
prompt. That asymmetry is intentional: the adapters are allowed to differ, the
skill core is not.

The bundles here supply MCP servers through a conventional `.mcp.json` at the
bundle root rather than a manifest pointer. Either works; the manifests must
agree.

## Catalog rules

Two catalogs, one Claude and one Codex, both at the repository root.

| Rule | Failure |
|---|---|
| Both catalogs publish the identical set of plugin names | `Claude and Codex catalogs publish different plugin names.` |
| Each Claude source is a repository-local `./plugins/...` path | `must use the same repository-local source in both catalogs` |
| The Codex source path equals the Claude source | same |
| No catalog entry declares `version` | `Claude catalog entries must omit version under Git-revision policy.` |

The two catalogs use different entry shapes — Claude takes a plain source
string, Codex takes a source object plus policy and category. Adding a bundle to
only one catalog is the single most common way to break this repository, and the
parity check exists specifically to catch it.

## Also validated

- Every JSON file under the catalogs, bundles, profiles, and schemas parses.
- Every desired-state profile validates against its schema.
- The repository's own unit tests pass.

## Version policy

The default branch is a rolling release channel. Plugin manifests and catalog
entries omit `version` deliberately, and validation enforces the omission —
adding one is a contract break, not a nicety. Clients resolve the newest merged
revision when they refresh.

The Claude client's own plugin validator reports the missing version as a
warning. That warning is expected and is not a gate.

## Secret hygiene

Nothing in this repository holds a credential. Bundles that need one commit only
the secret-manager project and config identifiers plus the variable-name
allowlist; the value is fetched at process start. CI runs a secret scan on every
pull request, but treat it as a backstop — review the diff yourself before
pushing.

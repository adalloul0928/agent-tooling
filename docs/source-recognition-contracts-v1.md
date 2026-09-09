# Source recognition contracts v1

Status: proposed S1 evidence-reader contract, September 8, 2026. This describes read-only interpretation of foreign source locks. It does not establish content authority, update a lock, fetch a repository, or change an installed skill.

## Pinned Vercel formats

The implementation targets `vercel-labs/skills` revision `80feb48868972d518436f26711509bc78595b5cb` only.

- Global v3 is `.skill-lock.json` at `$XDG_STATE_HOME/skills/` when an absolute XDG state root is explicitly supplied, otherwise `~/.agents/`. Entries contain `source`, `sourceType`, required `sourceUrl`, optional `ref` and `skillPath`, required `skillFolderHash`, installer timestamps, and optional plugin/provider metadata.
- Project v1 is `skills-lock.json` directly under an explicit project root. Entries contain `source`, optional `sourceUrl` and `ref`, `sourceType`, optional `skillPath`, required `computedHash`, and optional placement/provider metadata.

The reader accepts bytes and an explicit `SourceLockContext`. Path helpers construct candidate locations, but the parser does not inspect environment variables, read files, fetch a source, or execute provider code. Absolute lock and project paths are device state and never become portable repository claims.

## Evidence semantics

Each dictionary key becomes `skillNameHint`. A name is never an `ArtifactID`, and equal names from global and project locks remain separate evidence until S2 compares stronger identity facts.

`ref` becomes `requestedRef` evidence only. Branches and tags are not represented as approved revisions or installed commits.

Integrity algorithms remain separate:

- `githubSkillFolderTreeObjectID` is used only when a global v3 entry declares `sourceType: "github"` and supplies a valid Git object ID. It is not a repository commit or D1 content digest. A non-GitHub provider's `skillFolderHash` remains `vercelGlobalSkillFolderHashOpaque`, because the pinned schema does not establish that provider's hash algorithm.
- `vercelProjectSkillFolderSHA256V1` is project v1 SHA-256 over each recursively collected file's sorted relative path followed by its bytes, excluding `.git` and `node_modules` directories. It is distinct from D1 `sha256TreeV1`.
- `vercelWellKnownOpaque` preserves a bounded provider-defined value without assigning an undeclared algorithm.

Remote locators retain bounded normalized repository identity and credential-free HTTPS URLs. Credential-bearing locators become unavailable evidence and diagnostics name only the affected field. Project-local paths resolve against the explicit project root and remain device-only evidence.

Missing refs or skill paths, invalid integrity, local-only sources, malformed entries, and invalid locators produce explicit gaps or diagnostics. Valid sibling entries survive an invalid entry. Versions other than global v3 and project v1 return `unsupportedVersion` with no speculative entry decoding. Unknown fields in a supported version are ignored because these readers never rewrite or round-trip the foreign file.

S2 owns reconciliation. It must preserve an explicitly confirmed authority, present conflicts for review, and must not promote source-lock evidence automatically.

## Implemented reconciliation read model

`SourceEvidenceResolver` is a pure S2 submodule. Its caller supplies stable
artifact IDs and the context that matched each lock entry to an artifact. The
resolver does not read a checkout, infer identity from a name, fetch, install or
persist an authority change. `exactRelativePath` must come from a verified
unique match; a name, an ambiguous path or a repository-only match is
insufficient.

This first source-locator profile supports credential-free HTTPS GitHub
repository roots. Host/repository case and a terminal `.git` suffix normalize
for GitHub only. Other hosts remain unresolved rather than inheriting GitHub's
identity rules. Local paths, credentials, URL parameters, traversal, unsafe
refs, and invalid typed revisions never enter fetch proposals.

Confirmed bindings are returned unchanged. Invalid or duplicate confirmed
intent suppresses inferred replacements. Duplicate artifact IDs are reported
without selecting the first row. Native-owned packages, attached authoring
roots, package children, and unsupported artifact kinds cannot become
standalone upstream candidates. An already-upstream artifact requires its
existing confirmed binding.

Competing locators and competing revision/integrity facts are separate review
conflicts. Their alternatives remain visible but do not enter eligible fetch
groups. Requested refs, observed commits and provider-specific integrity
values remain distinct. The resolver does not call a newly observed commit
approved, and compares opaque values field by field for deterministic ordering.

Compatible new candidates share a proposed fetch group by canonical repository
and requested ref, with each artifact's package subpath retained. These are
planning data only. S2 still needs automatic foreign-lock-to-artifact matching
and the source-review UI. Actual source fetching, complete content capture and
reviewed updates belong to S3.

## Implemented Git checkout evidence capture

`GitCheckoutSourceReader` reads an explicitly supplied existing directory in the
background. It uses `/usr/bin/git` plumbing to capture the nearest checkout root,
Git directory, common Git directory, local branch, HEAD object ID, local/worktree
remote declarations and branch tracking configuration. These results are
device-only, non-Codable observations. Separate Git/common directories identify
a linked worktree; they are never used as a portable publisher identity.

The capture uses argument arrays, disabled hooks/fsmonitor and optional locks,
five-second command deadlines, cancellation, and a 64 KiB stdout/stderr limit.
Two bounded snapshots must agree. This detects ordinary concurrent metadata
changes; it is not an atomic Git transaction or an apply baseline. It performs
no fetch, credential lookup, status scan, index refresh or configuration write.
Cleanliness and whether local commits have been published remain unknown.

Configuration reads include repository and explicitly enabled worktree scopes,
exclude included files, and parse NUL-delimited records. The reader checks
`extensions.worktreeConfig` before querying worktree scope; Git rejects that
query in a multi-worktree repository when the extension is disabled. An inactive
`config.worktree` is not source evidence. An include directive makes automatic
recognition incomplete. Conflicting local/worktree values remain ambiguous;
the reader never selects a convenient first remote. Global URL rewrite rules,
SSH aliases, local repository remotes and arbitrary Git hosts are not inferred.
Raw unsafe remote URLs and Git errors never enter the result. Supported GitHub
HTTPS roots and literal `git@github.com:owner/repo` / `ssh://git@github.com/owner/repo`
forms normalize to credential-free HTTPS identities.

`recognize(artifactID:directory:)` connects the captured checkout to S2. The
inventory supplies an existing artifact's observed directory. Canonical real
paths establish its exact relative package location and exclude `.git` paths.
A configured upstream remote plus `refs/heads/...` merge target supplies a
review candidate. The tracked branch may differ from the local branch name;
neither is guessed from `origin` or `main`. Detached HEAD, unborn HEAD, missing
tracking, ambiguous remotes and omitted configuration remain unresolved.
Observed HEAD is retained as an observation, never an approved revision or a
claim that the current working files match that commit. The pure resolver still
enforces artifact authority and rejects native/plugin-child extraction.

The reader's command contract follows Git's official
[revision/path plumbing](https://git-scm.com/docs/git-rev-parse) and
[configuration scopes, includes and NUL output](https://git-scm.com/docs/git-config).
Temporary real-repository fixtures cover ordinary, unborn and detached linked
worktrees, per-worktree config, omitted includes and read-only file retention.
Stub fixtures cover changed metadata, bounded output, malformed responses,
credentials, conflicting tracking, cancellation and command shape. This is
local reader validation, not an app-wide automatic source scan or sync pilot.
An eventual inventory scan must deduplicate/cache checkout captures across
artifacts; the single-directory recognition API is not a per-row UI probe.

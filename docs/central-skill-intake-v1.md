# Central standalone skill commands

Status: additive S3/D3 service integration, September 8, 2026. These Swift APIs
operate on an explicitly initialized `WorkspaceRevisionStore` and
`CentralPackageContentStore`. The packaged app still uses the legacy store;
no user's existing setup is migrated or deployed by this packet.

## Prepare, review, apply

`WorkspaceSkillPreparation` produces a non-Codable `PreparedStandaloneSkill`.
It contains the immutable complete tree, parsed frontmatter, and a small
Codable review record. Its initializer is internal: public callers can prepare
personal content or request an upstream fetch, but cannot mark arbitrary local
bytes as a verified publisher revision.

- `personal(tree:)` explicitly prepares authored/adopted standalone content.
  `capturePersonal(directory:)` captures a complete existing folder first.
  Neither infers that a plugin child or third-party item is personal.
- `fetchUpstream(binding:cacheURL:)` uses the isolated Git repository adapter,
  captures its exported folder, records the actual fetched commit, and discards
  the temporary checkout. Repository/ref/path, publisher identity, commit and
  complete-tree digest remain separate values. Local HEAD observations and
  legacy/provider fingerprints are not accepted as proof of these bytes.
- The supported fetch route is credential-free HTTPS GitHub. It retains the
  adapter's explicit rejection of Git symlinks and submodules. Personal tree
  capture supports validated internal relative links. Rejected source content
  is not silently stripped or replaced with a partial skill.
- A root regular UTF-8 `SKILL.md` with valid required frontmatter is mandatory.
  Native/portable plugin-root markers reject standalone preparation, including
  case variants relevant to macOS. Plugin roots need whole-package intake.
  Invalid frontmatter is reported; preparation does not rewrite publisher files.

`StandaloneSkillIntakeCommand` binds an expected workspace revision,
idempotency key, stable artifact ID, label/aliases and exact content review.
An upstream review also needs explicit source/subscription IDs. Applying it
must supply the matching immutable preparation; the service does not recapture
a possibly changed source path between review and apply.

Personal intake creates one `centralPersonal` skill. Upstream intake creates
one `centralUpstream` skill and its lock/subscription. Another skill from the
same repository/ref reuses the explicitly selected source ID and adds its
relative path. Conflicting source identities, duplicate subscriptions for a
path, existing/tombstoned artifact IDs and invalid document references reject
the command. Names or matching content alone do not merge identities.

## Editing and upstream updates

`skillContent(artifactID:revisionID:)` returns verified complete content for an
immutable revision. A personal editor can replace selected entries in that
tree, prepare the resulting tree, then submit `StandaloneSkillUpdateCommand`.
The update includes both the expected workspace revision and old content digest.

Personal updates retain artifact identity, label, aliases and assignments.
Upstream updates additionally require the existing repository, requested ref,
package path, publisher and subscription linkage; only the approved commit,
approved content and declared skill name advance. A new publisher commit can
advance the lock even when the skill's bytes did not change. Preparing personal
content cannot overwrite an upstream skill. Native/package-owned, attached and
tracked artifacts cannot use this standalone update route. Ownership changes,
explicit forks and source rebinding require their own commands.

Both the prior and new content objects remain readable. A missing/damaged prior
object blocks an update instead of silently repairing history. This is central
library editing, not deployment: client folders, native plugin caches, source
repositories and device observations remain unchanged. Assignment reconciliation
must later show the reviewed difference and preserve modified deployments.

## Atomicity and replay

1. Match the prepared review and compute a domain-separated command digest,
   including provenance and the observed root-Git-metadata omission. Commands
   contain no embedded skill bytes or source filesystem path.
2. In one read transaction, resolve a prior receipt **before** checking the
   expected head, then validate the candidate document/device references.
   Invalid/stale new commands are rejected before publishing content.
3. Publish/verify immutable content without clobbering existing objects. Updates
   also verify their old object. Cancellation stops before metadata commit.
4. In a write transaction, check replay and expected head again, apply the
   mutation, validate/seal the document and atomically commit revision/head/receipt.

Two connections can prepare concurrently. A command commits once, replays its
original result, or encounters a changed head. Database rollback leaves the old
head intact and permits the same request to retry. A later command does not
invalidate a prior receipt or make a replay move the head backward.

A failure after content publication can leave an unreferenced complete object.
It is preserved, not deleted. The metadata receipt proves a historical library
change; replay does not claim that content is currently undamaged or installed
in any client. Current content reads verify the object separately. Cross-store
journaling, incomplete-stage recovery, reachability/retention, garbage collection,
sync history import and restore-as-a-new-revision remain Y2/Y3 work.

## Remaining integration

- Migration must join legacy identities and explicit materialization evidence
  to these objects, checkpoint raw legacy state and compare destination behavior.
- GUI, CLI and onboarding must share this service after cutover. No MCP operator
  endpoint is added; existing MCP methods continue to request/queue review.
- S3 still needs reviewed destination reconciliation; A3 needs native executor
  integration and postconditions. This packet does not complete either ticket.
- Complete native/Agent Plugins packages stay whole. Their native install/update
  mechanism, package hierarchy and compatibility rules remain separate.
- Fixture tests cover local state and failure/retry behavior. Packaged UI,
  native-client invocation and real two-Mac verification remain required.

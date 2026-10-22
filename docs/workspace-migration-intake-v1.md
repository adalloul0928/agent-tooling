# Workspace migration intake v1

Status: checkpoint-based preparation and a Settings entry point are implemented.
The progress ledger records fixture and packaged-app evidence; this is not an
automatic migration of a user's existing workspace.

## Readiness and ownership

`WorkspaceMigrationIntake.review` interprets one immutable legacy checkpoint.
It recommends central management only from existing personal ownership or an
explicit upstream repository binding. Publisher names and installation flags
cannot confer ownership. Bundled children stay with their native plugin; they
are never offered as standalone copies when the parent is unresolved.

An upstream recommendation requires an exact installed directory and recorded
revision. Source and subscription identities are deterministic within the
workspace and survive repeated inspection. When multiple installed folders are
recorded, Settings offers an explicit starting-folder choice. Native routes require actual client observations; skill
member paths must agree across clients. Native placements derive only from
explicit active-configuration bindings and enabled clients. An observation
alone never creates assignment intent.

Native MCP members use their exact observed declaration identity under the
plugin. No independent file path is required or invented. Every declared member
must exist in the captured inventory and have one unambiguous parent; a missing
or conflicting member blocks the whole package. Required-MCP configuration
references still resolve to that child for fidelity, while assignment and
installation remain whole-plugin operations.

`WorkspaceMigrationCandidatePreparationService.preview` verifies all choices
against the same checkpoint. Personal trees come from the exact legacy library
location. Upstream trees must match their recorded installed fingerprint and
retain repository, requested ref, subdirectory and installed revision. Complete
trees are captured and checked before the existing inventory/configuration
assembly and assignment migration seal the candidate. No network fetch occurs.

`WorkspaceMigrationUpstreamIntake` exposes only exact recorded folders from a
validated repository binding. Each selection is bound to the repository, ref,
subdirectory, installed commit, folder and recorded fingerprint. Check again
captures new evidence and rejects stale selections; a previously reviewed skill
still requires confirmation if only one folder remains. Losing its repository
binding leaves a blocker rather than converting it to a personal or tracked
skill. Missing or malformed installed evidence exposes no selectable folders;
the last checked remote revision cannot substitute for the installed revision.
Native children remain excluded even when their parent cannot yet be resolved.
The saved review retains the selected device-local path and upstream revision.

`WorkspaceMigrationNativePlacementIntake` keeps unambiguous user-scope plugins
automatic. Project/local-project plugins require an explicit choice of logical
project and local root. Settings offers confirmed project mappings and can add
an existing folder as another candidate; choosing a folder alone does not select
the placement. Equal project names at distinct roots stay separate. Only used
additional projects enter the prepared workspace. The package installation path
is never interpreted as a project root.

Native selection evidence includes the active configuration's inheritance
chain, scopes, roots and effective binding origin, optional desired enablement,
routes, observed scope/package metadata and selected project
identity/name/root. Changed evidence clears a previous choice, including a
project-scoped observation changing to user scope. Missing/contradictory
metadata or unsupported scope remains a blocker. Native project folders must
still exist at each inspection and immediately before staging. A missing folder
removes its candidate and clears its selection; added unused folders are omitted.
Legacy Claude `User`/`Local`
tokens are interpreted as user/local-project scope while the original tokens
remain part of the evidence. Existing disabled assignments remain disabled;
bundled children receive no independent assignment or central copy. These are
migration intent records, not proof that a native adapter supports deploying
that scope; deployment compatibility remains a separate reviewed gate.

Native catalog records match resolved plugin roots automatically using the
parser-preserved `codex:<plugin ID>` or `claude:<plugin ID>` identity and an exact
observed client route. Codex and Claude catalog aliases can identify the same
whole plugin. Display names, publisher labels and install commands never create
the match. Contradictory native metadata, competing roots and changed reviewed
bindings block preparation. A valid native catalog row without an observed
resolved root stays in device-local catalog data, including a stale installed
flag; it creates no content, assignment or duplicate plugin.

Startup refresh preserves cached native rows for excluded clients and failed or
incomplete catalogs. Freshly parsed rows replace matching exact IDs. Only a
recognized complete response can remove other cached rows for that client;
unknown JSON shapes, traversal limits and Codex's installed-marketplace fallback
cannot establish a complete global catalog. Refresh failures remain visible and
do not advance the catalog's last-successful-refresh timestamp. This retention
rule currently covers native client catalogs, not every external source provider.

`WorkspaceManagedMCPMigrationIntake.review` resolves existing standalone managed
connections when the checkpoint contains a valid definition and exact current
scope/client information. Settings passes these typed resolutions through the
existing candidate validation. Parsed command arguments, normalized HTTP
addresses, authentication, credential names and workspace roots stay in device
state. Even a public HTTPS address remains device-bound until an explicit
portable-sharing decision. Deterministic manual contributions preserve each
current app target without inventing an enable/disable choice.

Native plugin members are excluded. Invalid definitions, credential names,
authentication, scopes, duplicate identities and conflicting client records
remain named review issues; resolving other rows cannot clear their blockers.
Project/local-project connections require an explicit logical-project mapping.
Settings now groups those connections and personal/managed-policy configurations
by their exact saved folder. The user enters a project name and confirms that
folder once; the affected records share one logical identity while preserving
their Project or This project only scopes. Equal names at different roots do not
merge projects. Folder paths remain device-only, and no folder is moved or chosen
through a new picker. Missing/noncanonical paths remain visible blockers.

`WorkspaceMigrationProjectIntake` validates mappings and builds exact,
policy-qualified configuration keys. Duplicate identities/roots, unreferenced
mappings and blank project names are rejected. Configuration conversion also
rejects supplied bindings for absent, differently owned or non-project profiles.
Check again reads a fresh checkpoint and retains confirmations only for roots
still required there; MCP and configuration resolutions are rebuilt. Editing a
confirmed name prevents staging until it is confirmed again. The saved review
shows the resulting projects and local paths before initialization.

Nonnative marketplace and other unresolved source/placement records continue to
use their existing contracts. Missing mappings do not omit inventory or downgrade
editable/upstream/native ownership to tracking.

## Preparing and selecting a workspace

Settings exposes **Review migration**. Before opening it, `AppModel` must be idle
with no pending plan. An active review gates new mutations, native/source jobs,
runtime refreshes and draft writes. Direct persistence has a matching backstop.
Already-running safety reviews, runtime work and native plugin probes prevent
entry rather than being interrupted halfway through a write.

Inspection creates no migration directory. **Save migration review** creates
private revision/content/checkpoint roots beside the retained legacy store and
writes a canonical `review.json` recovery descriptor before durably staging the
candidate. The descriptor is an explicit recovery handle, not an authority
selection or an automatically discovered resume pointer. A failed staging
attempt is reported and may leave an unused private directory; close and reopen
the review to prepare a fresh attempt.

The existing migration UI then initializes the exact reviewed record and offers
a separate workspace-selection confirmation. Successful selection reloads the
application root into the guarded writable library without re-enabling the old
model. Cancelling before selection resumes the retained workspace only if the
authority registry still allows it. A changed or corrupt registry cannot
silently unfreeze the old writer.

## Explicit home and verification

Normal and retry app launches pass the selected home to `ProcessCommandRunner`.
That home controls both child `HOME` and executable lookup; the environment
allowlist remains unchanged. The migration pilot also uses its explicit home
when opening the retained app. This prevents a disposable fixture launch from
discovering the real user's client executables through a hard-coded home.

Disposable tests cover read-only inspection, complete-tree/source validation,
durable staging, mutation gating, cancellation, stable upstream identities and
explicit-home command execution. Packaged inspection covers Settings through
selection and a subsequent assignment save. The fixture's native home remains
empty and its original personal skill file remains intact. These checks do not
establish native installation, production-scale latency or two-Mac sync.

Onboarding integration, complete interactive source/nonnative catalog and native-placement resolution,
automatic pending-review recovery, and reviewed native deployment remain open.

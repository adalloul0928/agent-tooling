# Propagation

Merging publishes a skill. It does not install one. This is the step that gets
skipped, and the symptom is confusing: the skill is visibly on the default
branch, and the client still does not know it exists.

## The five layers

A capability is only usable when all five line up, and each is independent:

1. **Source** — the bundle in this repository.
2. **Catalog** — the marketplace entry advertising it.
3. **Installation** — the client and scope where the bundle is enabled.
4. **Authentication** — only relevant if the skill drives an external service.
5. **Session** — a client process started *after* the update.

Publishing satisfies 1 and 2. Nothing satisfies 3 automatically.

## Two cases, very different cost

**Skill added to an already-installed bundle.** Refresh the catalog, update the
bundle, start a fresh session. No per-machine install decision, nothing to
enable. This is why placing a skill in an existing bundle matters.

**New bundle.** Every machine and every client additionally needs an explicit
install. A catalog refresh advertises a new bundle; it never installs one. Until
someone runs the install, the skill does not exist for that client — and the
desired-state check will report it as required-but-missing, which is the
intended signal, not a bug.

## Per client

Both clients follow the same shape with their own commands:

1. Refresh the `agent-tooling` catalog. Both clients track the default branch,
   so a refresh resolves the newest merged revision.
2. Update the bundle, or install it if the bundle is new.
3. Start a fresh session. A running session does not pick up a newly installed
   skill.

The private catalog only needs to be registered once per client per machine.
Official first-party catalogs are built in and are never re-added.

Scope differs and matters. Most bundles here are enabled per project through the
project's committed client settings; one is deliberately user-scoped because its
skills run unattended from a scheduler in whatever directory that run uses, and
a project-scoped bundle would not be active there. Match the scope the bundle
was designed for rather than defaulting.

One asymmetry to know: as tested, Codex plugin installation and enablement are
user-scoped only — a bundle declared in a project's Codex configuration does not
activate. Anything project-critical for Codex has to be a committed project
skill or MCP, or the bundle stays enabled globally.

## Verify, do not assume

Confirm the skill is present from the client's own listing, and confirm the
bundle it came from is the one you expect. A skill can also exist as a
standalone user-scoped copy from an earlier install, which is exactly the drift
that makes "it works on my machine" untrue on the next one.

The repository's desired-state checker reads native client configuration and
reports drift read-only. Use it after a release rather than trusting that the
update ran.

## Canary

Three cases, in a fresh session, per client that is supposed to have it:

| Case | What it proves |
|---|---|
| Explicit invocation by name | Installed and loadable |
| A phrase the user gave during the interview | The description actually triggers |
| A near-miss phrase that should *not* fire it | The description is not over-broad |

The middle case is the one that fails. A skill reachable only by its own name is
half-built — the user has to remember it exists, which is the problem the skill
was supposed to solve.

If the skill bundles scripts, references, or assets, exercise one of them in the
canary. Path resolution from an installed location is not the same as from the
repository checkout, and a broken relative path only shows up once installed.

## Surfaces this does not reach

A merge to the default branch says nothing about hosted account state. Account
skill stores, chat connectors, and cloud execution environments are separate
destinations with their own installation and authentication, and each has to be
verified on its own. Do not report a skill as available everywhere on the
strength of a green pull request.

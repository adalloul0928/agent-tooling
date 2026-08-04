---
name: skill-forge
description: >-
  Author a new Agent Skill and publish it to the agent-tooling repository so both
  Claude and Codex pick it up. Use when the user says "let's make a skill", "turn
  this into a skill", "capture this as a reusable workflow", or describes a
  repeatable procedure they want available in future sessions. Interviews for the
  name and trigger phrasing, checks for name collisions across owned and vendor
  skills, writes one portable SKILL.md into the right plugin bundle, adds native
  Claude and Codex adapters plus catalog entries when a new bundle is needed,
  validates against the repository contract, opens a pull request with
  auto-merge, then reports the per-client refresh required to consume it. Needs a
  repository checkout, a shell, and git.
---

# Skill forge

Turn "we should make a skill for this" into a merged, installable skill without
hand-walking the repository contract every time.

This skill writes to `agent-tooling`. Everything it produces is one portable
`SKILL.md` plus, only when a new bundle is genuinely needed, the two native
adapter manifests and two catalog entries that publish it.

**Not the same as vendor skill authoring.** Anthropic's `skill-creator` is a
general authoring aid and is Claude-only. This skill is about *placement and
publication* under this repository's contract — one physical core, dual
adapters, catalog parity, no version fields, secret hygiene, and a per-client
consume step. Borrow authoring craft from wherever; get the contract from here.

## Prerequisites

A checkout of this repository, a shell, and git. Confirm the checkout is on the
latest default branch before starting — authoring against a stale tree is how
name collisions and duplicated work happen.

If the checkout is in an ephemeral or remote environment, say so up front: the
work only persists once pushed, and the user's own machine will not see the new
skill until it pulls and the client refreshes.

## Step 1 — interview, one question at a time

Do not batch these. Each answer changes the next question.

1. **What should it do, in one sentence?** If the answer is really two
   capabilities, say so and offer to split. Two focused skills trigger more
   reliably than one broad one.
2. **When should it fire?** Collect the actual phrasings the user would type,
   plus at least one case where it should *not* fire. Both go into the
   description. This is the highest-leverage question in the interview — a skill
   that never triggers is worse than no skill, because it still costs context.
3. **Which bundle?** See the placement table below. Propose one, do not ask
   open-ended.
4. **Does it need bundled files?** Scripts, reference documents, templates. Most
   skills need none. Only add what the workflow actually reads.
5. **Does it need an MCP server?** Almost always no. If yes, stop and confirm
   separately — an MCP changes the bundle's authentication story and is not a
   routine skill addition.

### Placement

| The behavior is | Bundle |
|---|---|
| Reusable across projects, development-oriented | `developer-workflows` |
| Personal, non-work | `personal` |
| PUMPD research/planning/review pipeline | `cyrus-workflows` |
| PUMPD local maintenance, outside the pipeline | `pumpd-workflows` |
| Scheduled, unattended PUMPD scan | `pumpd-automations` |
| Wet In Seattle / IAWIS | `wet-in-seattle` |
| Specific to one application repository | **Not here** — commit it in that repository |

Default hard toward an **existing** bundle. A new bundle is not a bigger version
of a new skill; it is a new install obligation on every machine and every client,
because a catalog refresh never installs a new plugin on its own. A skill added
to an already-installed bundle arrives with the next plugin update and needs no
per-machine action.

If the honest answer is "this belongs in the application repository," say so and
stop. Placing project-critical behavior here is how it goes missing from cloud
sessions that only have the application checkout.

## Step 2 — collision check before writing a line

Skill names are a flat namespace per client. Two skills with one name make
triggering ambiguous, and the vendor installer silently overwrites rather than
warning. This repository has been bitten twice; do not skip this.

Check the proposed name against, at minimum:

- every `SKILL.md` directory under `plugins/*/skills/` in this repository;
- skills installed at user scope by the vendor `skills` CLI for each client;
- skills provided by installed plugins, including Anthropic's and OpenAI's
  catalogs — `skill-creator`, `docx`, `pdf`, `pptx`, `xlsx` and similar common
  names are already taken.

Enumerate the repository directly rather than trusting recall.

If the name is taken, rename — never overwrite. Prefer a distinctive name over a
generic one for exactly this reason.

## Step 3 — write the skill

Start from [`assets/skill-template.md`](assets/skill-template.md).

Frontmatter carries `name` and `description` only. `name` must equal the
directory name. Platform-specific metadata belongs in the adapter manifest, not
here.

The description is the trigger surface. Write it to match how the user actually
speaks, include the negative case, and keep it specific — every installed
skill's description is loaded for matching in every session, so a vague
description is both a missed trigger and a standing context cost.

Body rules, all enforced by validation or by the authoring rules:

- **No hard-coded client installation paths.** Not the user-level Claude or Codex
  configuration directories, not a marketplace cache, not a home-directory
  plugin path. The contract check greps for these and fails the build. Describe
  them in capability terms instead: "the client's user-scoped skills directory".
- **Resolve bundled files relative to the skill directory.** Reference them as
  `references/thing.md` or `scripts/thing.sh` from the skill root.
- **Stay inside the package.** Never reference a file outside the bundle;
  symlinks that escape the package fail validation.
- **Capability terms, not product names**, wherever a portable description does
  the job. Say "a repository write capability", not a specific tool name.
- **No secrets, tokens, credentials, or machine-specific absolute paths.** If the
  workflow needs a secret, it fetches it at runtime from the secret manager; the
  repository stores only the identifier and the variable name.

Detailed rules and the exact failure each one produces:
[`references/repo-contract.md`](references/repo-contract.md).

## Step 4 — new bundle only

Skip entirely when adding to an existing bundle. When a new bundle is genuinely
justified, all four of these are required and validation fails on any omission:

- `plugins/<bundle>/.claude-plugin/plugin.json`
- `plugins/<bundle>/.codex-plugin/plugin.json`
- an entry in the Claude catalog
- an entry in the Codex catalog

The two catalogs must publish the **same set of plugin names** and the **same
repository-local source path** for each. Both manifests must **omit `version`**
under the rolling-Git-revision policy. The manifest `name` must match the
catalog entry name. See [`references/repo-contract.md`](references/repo-contract.md)
for the shapes.

## Step 5 — validate

Run the repository's static validation script from the repository root. It is
the same gate CI runs, so a clean local run means the pull request should pass.
Fix everything it reports before opening the PR — do not open a PR to see
whether it passes.

It requires a JSON processor, Python 3, ripgrep, and the Agent Skills reference
validator on `PATH`. If the validator is missing, install it rather than
skipping the step; it is the check that catches frontmatter mistakes.

The repository also has a full native validation script that additionally
requires both client CLIs and smoke-installs every bundle into isolated client
homes. Run it when the change touches manifests or catalogs. For a plain skill
addition to an existing bundle, static validation is the proportionate gate.

## Step 6 — land it

1. Branch from the latest default branch. Never commit directly to it — it is
   the rolling release channel every client tracks, so an unreviewed skill
   reaches every machine on the next refresh.
2. Commit with a Conventional Commit message, e.g.
   `feat(developer-workflows): add <name> skill`.
3. **Scan the diff for secrets before pushing.** CI runs a secret scan, but the
   scan is the backstop, not the review.
4. Push and open a pull request describing what the skill does, when it triggers,
   and which bundle it lands in.
5. Enable auto-merge so it lands once checks are green.

Two auto-merge traps worth knowing before you hit them:

- **Auto-merge only waits for checks that branch protection actually requires.**
  With no required status checks configured, enabling auto-merge can merge as
  soon as the PR is mergeable — potentially before CI reports. If the point is to
  gate on CI, the required checks must be configured on the default branch;
  otherwise treat auto-merge as "merge now" and wait for CI yourself.
- **Required review from code owners deadlocks a self-authored PR.** The bundle
  directories are code-owned. If branch protection requires a code-owner review
  and the code owner is the PR author, auto-merge waits forever, because an
  author cannot approve their own pull request. Report that state rather than
  silently leaving the PR open.

## Step 7 — report how to consume it, then canary

Merging publishes; it does not install. **A skill is not usable anywhere until
each client refreshes the catalog and updates the bundle.** Finish by telling the
user exactly what to run per client, and that a fresh session is required before
the new skill is discoverable.

Per-client steps and the canary matrix:
[`references/propagation.md`](references/propagation.md).

Then canary the skill in a fresh session — explicit invocation by name, one
implicit trigger from a phrase the user gave in Step 1, and the non-trigger case.
A skill that only responds to its own name is half-built.

## When to refuse

- The request is really an application-specific rule. Point at that repository.
- The capability already exists in an installed vendor skill. Recommend it
  instead; a duplicate costs context and creates a trigger collision.
- It is a one-off. A skill earns its place through repeated use — a single task
  is just a task.

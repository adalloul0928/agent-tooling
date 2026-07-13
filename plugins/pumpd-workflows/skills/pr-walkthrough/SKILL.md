---
name: pr-walkthrough
description: Explain a pull request or branch as a teaching and reviewer-prep walkthrough. Use when the user asks to walk through a PR, understand why implementation choices were made, prepare for review, document rationale, compare alternatives, explain tradeoffs, or cite official docs/upstream GitHub sources for a PR's patterns and dependencies.
---

# PR Walkthrough

## Purpose

Produce a rationale-first walkthrough of a pull request. Treat this as explanation and reviewer preparation, not a bug-hunting code review unless the user explicitly asks for review findings.

## Workflow

1. Resolve the PR or comparison range.
   - Prefer an explicit PR URL or number from the user.
   - Otherwise resolve the current branch PR with `gh pr view`.
   - If no PR exists, compare the current branch with its merge base against the default or integration branch.

2. Collect raw PR context.
   - Resolve bundled resource paths relative to this skill directory.
   - Run `scripts/collect_pr_context.py --repo <repo>` when available.
   - If the script cannot run, use `git status`, `git log`, `git diff --stat`, `git diff --name-only`, `gh pr view`, and `gh pr diff`.
   - Inspect the actual changed files before explaining intent.

3. Identify the decision structure.
   - Group changes by domain such as mobile, backend, database, infra, tests, docs, or dependencies.
   - For each group, infer the implementation intent from the diff and existing repo conventions.
   - Distinguish documented facts from your inference.

4. Gather supporting evidence.
   - Prefer local repo conventions and existing patterns first.
   - Use official docs, upstream GitHub repos, release notes, or changelogs for library/API/tooling choices.
   - Browse or use docs tools for current dependency behavior, version-gated capabilities, or claims that may have changed.
   - Cite sources with links. Do not cite generic blog posts unless no primary source exists.

5. Explain tradeoffs.
   - Explain what changed and why that approach fits the repo.
   - Name reasonable alternatives and why they were not chosen.
   - Surface weak spots, risk, migration costs, and follow-up work without overstating certainty.

6. Verify before finalizing.
   - Report checks already run from PR body, local logs, or CI.
   - If no verification is visible, say so and suggest the smallest relevant verification.

## Output Shape

Use the template in `references/output-template.md` unless the user asks for a different format.

Keep the answer concise enough to be useful in chat. For large PRs, lead with the executive summary and provide deeper sections only for the highest-impact decisions.

## Evidence Rules

- Include clickable local file links for local code references when the file is available.
- Include web links for official docs, upstream release notes, or GitHub source references.
- Label uncertainty with phrases like "I infer this because..." rather than presenting guesses as facts.
- Do not defend every change. Include a short "Risks And Questions" section.
- Do not post comments to GitHub, edit docs, or change code unless the user explicitly asks.

## PUMPD Defaults

When used inside `pumpd-mobile-app`:

- Treat `preview` as the default integration branch.
- Prefer PUMPD skills and local docs for architecture, Supabase, testing, UI, and Expo conventions.
- Use official docs for Sentry, Expo, Supabase, React Native, TanStack Query, and dependency-version claims.
- Call out when a choice was made to preserve agent workflows, observability, CI, or preview-deploy behavior.

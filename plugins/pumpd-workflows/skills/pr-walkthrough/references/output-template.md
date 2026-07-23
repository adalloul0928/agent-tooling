# PR Walkthrough Output Template

## Executive Summary

- What the PR is trying to accomplish.
- The main implementation strategy.
- The most important review context.

## Change Map

Group changed files by intent, not by raw directory list. Include file references for the main files only.

Example:

- Mobile observability: `apps/mobile/src/services/...`
- Edge Function telemetry: `apps/backend/supabase/functions/...`
- Tests and docs: targeted tests plus runbook updates

## Key Decisions

For each important decision:

### Decision Name

- What changed:
- Why this pattern:
- Evidence:
- Alternatives considered:
- Tradeoffs:

## Evidence Map

List the strongest source anchors:

- Local files:
- Repo docs or conventions:
- Official docs:
- Upstream release notes or GitHub source:

## Verification

Summarize checks from PR body, CI, and local runs. Separate confirmed checks from recommended checks.

## Risks And Questions

List review questions, migration risks, operational risks, and follow-up work.

## Reviewer Prep

Provide likely reviewer questions and short answers.

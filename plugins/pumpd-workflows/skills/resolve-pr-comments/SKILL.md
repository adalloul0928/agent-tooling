---
name: resolve-pr-comments
description: Fetch PR review comments, apply fixes, push, and post resolution responses
---


# Resolve PR Comments

Fetch unresolved review comments from a GitHub PR, apply fixes, and respond.

## Input

PR number or URL: $ARGUMENTS

## Workflow

1. **Fetch comments**: Use `gh` to get unresolved review comments.
   ```bash
   gh pr view <number> --json reviewDecision,reviews
   gh api repos/{owner}/{repo}/pulls/<number>/comments
   ```

2. **Categorize comments**:
   - **Actionable**: Code changes requested — fix these.
   - **Questions**: Clarification needed — draft a response.
   - **Nits**: Style/preference suggestions — fix if trivial, respond if opinionated.

3. **Apply fixes**: For each actionable comment:
   - Read the file at the mentioned path and line.
   - Apply the requested change following PUMPD conventions.
   - Stage the fix.

4. **Run quality gate**: After all fixes:
   ```bash
   npm run lint
   npm run typecheck
   npm run test:run
   ```

5. **Commit and push**:
   - Create a single commit: `fix: resolve PR review comments`
   - Push to the PR branch.

6. **Post responses**: For each comment, draft a reply:
   - Actionable: "Fixed in <commit-sha>" with brief explanation.
   - Questions: Answer with context from the code.
   - Nits: "Fixed" or explain why not.

7. **Report**: Summary of comments resolved, files changed, quality gate status.

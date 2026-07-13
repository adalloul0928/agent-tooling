---
name: pr
description: Create a GitHub PR using PUMPD conventions and gh CLI
---


# Create Pull Request

Create a PR from the current branch using `gh`.

## Workflow

1. Run quality checks first:
   - `npm run lint`
   - `npm run typecheck`
   - `npm run test:run`
2. Gather context:
   - `git rev-parse --abbrev-ref HEAD`
   - `git diff main --name-only`
   - `git diff main --stat`
   - `git log --oneline main..HEAD`
3. Draft a conventional-commit style PR title (`feat:`, `fix:`, `refactor:`, etc.).
4. Draft PR body with sections:
   - `## Summary`
   - `## Changes`
   - `## Testing`
   - `## Notes` (optional)
5. If a Linear issue ID is discoverable from branch/commits, include it in Notes.
6. Create the PR with `gh pr create`.
7. Return:
   - PR URL
   - Final title
   - Final body

If quality checks fail, stop and report failures instead of creating the PR.

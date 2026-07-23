---
name: doc-sync
description: Analyze code changes and update matching documentation in /docs
---


# Documentation Sync

Analyze staged or branch changes and update relevant documentation.

## Input

Optional scope or focus: $ARGUMENTS

## Workflow

1. **Identify changes**:
   ```bash
   git diff --staged --name-only   # staged changes
   git diff main --name-only       # or branch changes vs main
   ```

2. **Classify change types**:
   - New features -> may need new docs or feature guide updates
   - API/service changes -> update architecture or data layer docs
   - Component changes -> update UI or component docs
   - Config changes -> update getting-started or build docs
   - Test changes -> update testing docs

3. **Map changes to docs**:
   - `src/features/*` -> `docs/features/`
   - `src/services/*` -> `docs/systems/`
   - `src/components/*` -> `docs/architecture/`
   - `src/stores/*` -> `docs/architecture/state-management.md`
   - `app.json`, `eas.json` -> `docs/development/build-deploy.md`
   - `package.json` -> `docs/getting-started.md`
   - `.maestro/*` -> `docs/testing/maestro-e2e.md`
   - `src/test/*` -> `docs/testing/unit-testing.md`

4. **Update docs**: For each mapped doc file:
   - Read the current doc.
   - Identify what's outdated based on the code changes.
   - Apply minimal, accurate updates.
   - Preserve existing structure and tone.

5. **Report**:
   - Files changed in code
   - Docs updated
   - Docs that may need manual review
   - Any new docs that should be created

# Public application extraction boundary

The public product is a separate Apache-2.0 repository, tentatively named
`agent-tooling-app`. Creating or publishing that repository is a separately
approved release action. This private catalog remains a source that the public
application may connect to only when its owner adds it.

## Content allowed in the public repository

- `apps/agent-tooling-macos/Package.swift`
- `AgentToolingCore`, `AgentToolingApp`, and `AgentToolingCLI` sources
- app resources, public package-format schemas, and non-personal fixtures
- the consolidated product/architecture site
- app tests, packaging scripts, CI, signing documentation, and release policy
- a new Apache-2.0 `LICENSE`, public `SECURITY.md`, contribution guide, and code
  of conduct created for the public repository

The app must open with an empty local SQLite workspace, discover supported
clients, create a local library, and install fixture packages without a GitHub
account or access to this repository.

## Content forbidden from the public repository

- `plugins/`, `.claude-plugin/`, `.agents/plugins/`, and private profiles
- Life OS, PUMPD, Cyrus, Wet in Seattle, mobile-development, or personal code
- local tooling inventories, rollout notes, account identifiers, private source
  URLs, machine paths, signing material, secrets, OAuth state, or caches
- generated catalog adapters derived from the private packages

## Extraction gate

1. Export only the allowlisted app paths into a new clean directory.
2. Add the public license and governance documents there—not to this private
   catalog, whose mixed contents have different ownership and licensing.
3. Scan the exported tree for private names, absolute paths, secrets, package
   contents, and Git history leakage.
4. Build and test from a clean macOS account with no access to this repository.
5. Verify empty launch, client scan, local library creation, fixture install,
   plan review, apply, receipt, rollback, and diagnostic export.
6. Review the exact export and obtain separate approval before repository
   creation, first push, signing, notarization, or publication.

Git is an optional provider in the public product. Local folders and SQLite are
the zero-account default; Git repositories, private catalogs, and encrypted
archives are opt-in sources or backup/sync providers.

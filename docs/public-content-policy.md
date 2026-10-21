# Public content

This repository contains the macOS app, public client adapters, the Raycast
companion, synthetic tests, and product documentation. Private catalogs and
workstation settings belong in separate repositories or local configuration.

Before contributing:

- Use documented public client interfaces.
- Use example domains, synthetic accounts, and temporary directories in tests.
- Keep personal and employer data, internal endpoints, account identifiers,
  signing credentials, and local machine paths out of every file.
- Capture screenshots with a disposable home and workspace. Review the pixels
  as well as image metadata.
- Run `./scripts/check-public-content` and a secret scan before committing.

The content check rejects private catalog directories, known private vocabulary,
personal home paths, unexpected email addresses, credential files, and broken
local Markdown links. Vocabulary fingerprints avoid reproducing removed private
names in the checker. Gitleaks separately checks for credentials.

These checks cover the current files. They do not erase Git history, old pull
request refs, releases, forks, or cached copies. Review those surfaces before a
first public release; history cleanup is a separate operation.

Release artifacts must be built from the reviewed public source in CI. A signed
app includes the publisher's public certificate identity.

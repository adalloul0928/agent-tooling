# macOS releases

Agent Tooling ships as a DMG for **Apple Silicon Macs running macOS 26 or
later**. Users drag the app into Applications. Xcode, Swift, and a repository
checkout are not required.

The release workflow signs the app and its helpers with Developer ID, checks
the packaged resources, verifies the mounted DMG, submits it to Apple for
notarization, and staples the ticket. GitHub Releases receives the DMG, a
SHA-256 checksum, an SPDX manifest, and build attestations.

The app includes the repository's [MIT license](../LICENSE) at
`Contents/Resources/LICENSE.txt`. Yams and LibYAML notices remain in the app's
resource bundle. The SPDX manifest identifies Agent Tooling's license as MIT
and lists these dependencies separately.

## First release status

A signed public release has not been published yet. The release environment,
Apple credentials, and repository variables below must be configured first.
CI artifacts and local development DMGs are ad-hoc signed and are intended for
testing. They are not notarized public downloads.

## Configure signing

1. Join the Apple Developer Program and create a **Developer ID Application**
   certificate. Export its certificate and private key as a password-protected
   `.p12` file.
2. Create an App Store Connect API key with access to the notary service. Keep
   its `.p8` file, key ID, and issuer ID outside this repository.
3. Create a GitHub Actions environment named **`macos-release`**. Require
   approval from a release reviewer, prevent self-review, and restrict it to
   tags matching `agent-tooling-app-v*`.
4. Set the repository Actions variable **`MACOS_SIGNING_TEAM_ID`** to the certificate's
   ten-character Team ID. The workflow rejects any different signing team.
5. Add these secrets to **`macos-release`**, not to the repository-wide secret
   store:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting the `.p12` |
| `APPLE_NOTARY_KEY_BASE64` | Base64-encoded App Store Connect `.p8` |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER_ID` | API issuer ID |

From a checkout, the GitHub CLI can set an encoded file without printing it:

```sh
base64 -i DeveloperIDApplication.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 --env macos-release
base64 -i AuthKey.p8 | gh secret set APPLE_NOTARY_KEY_BASE64 --env macos-release
gh secret set MACOS_CERTIFICATE_PASSWORD --env macos-release
gh secret set APPLE_NOTARY_KEY_ID --env macos-release
gh secret set APPLE_NOTARY_ISSUER_ID --env macos-release
```

The app identifier is `dev.agenttooling.app`; the helper identifiers append
`.cli` and `.mcp`. Developer ID certificates expose the certificate holder's
name and Team ID as public signature metadata.

## Restrict release access

- Protect `main` with pull request review and required validation.
- Protect `agent-tooling-app-v*` tags with a ruleset that restricts creation to
  release managers and prevents updates and deletion.
- Set the repository variable **`MACOS_RELEASE_ALLOWED_ACTORS`** to a
  comma-separated list of GitHub logins permitted to publish a release.
  Both the original actor and anyone rerunning the workflow must be listed.

A release requires an annotated tag whose commit is in the default branch's
history. The workflow checks the tag, actor, and public source before requesting
access to the release environment. It checks the tag again before signing.

## Publish

After the release changes have merged and validation passes, create an
annotated tag from the intended commit on `main`:

```sh
git tag -a agent-tooling-app-v0.1.0 -m "Agent Tooling 0.1.0"
git push origin agent-tooling-app-v0.1.0
```

Approve the `macos-release` environment deployment in Actions. Publication
happens only after tests, signature verification, notarization, stapling, and
Gatekeeper assessment pass.

Each release includes the same filenames:

- `Agent-Tooling-arm64.dmg`
- `Agent-Tooling-arm64.dmg.sha256`
- `Agent-Tooling-arm64.dmg.spdx.json`

The stable DMG filename supports GitHub's
`releases/latest/download/Agent-Tooling-arm64.dmg` URL. Link to the repository's
Releases page until the first release is available.

## Install or update

Download the DMG from GitHub Releases, open it, drag **Agent Tooling** into
**Applications**, eject the disk image, and open the app. To update, quit the
app and replace the copy in Applications. The library is stored separately in
Application Support.

From a checkout, you can also download and check the latest release:

```sh
gh release download --pattern 'Agent-Tooling-arm64.dmg*'
shasum -a 256 --check Agent-Tooling-arm64.dmg.sha256
open Agent-Tooling-arm64.dmg
```

The first channel uses manual updates. A Homebrew cask can follow once a
signed release has been installed successfully on another Mac.

## Build a development DMG

From `apps/agent-tooling-macos`:

```sh
./scripts/package-app.sh "$PWD/.build/Agent Tooling.app"
./scripts/create-dmg.sh "$PWD/.build/Agent Tooling.app" "$PWD/.build/Agent-Tooling-development.dmg"
./scripts/verify-dmg.sh "$PWD/.build/Agent-Tooling-development.dmg"
```

`create-dmg.sh` verifies the source app and mounts the resulting disk image to
check the copy inside it. It generates the Finder background and icon layout
for the app's version, including the Applications shortcut and installation
instructions. The generator requires the macOS Swift toolchain; installing the
finished DMG does not.

These commands use ad-hoc signatures unless a signing
identity is supplied. Packaging remaps compiler paths, removes debug metadata,
and rejects executables that still contain the builder's home or checkout path.
Distribute public builds through the release workflow.

# Releasing Agent Tooling for macOS

The release workflow builds an Apple Silicon app on GitHub Actions, signs it
with Developer ID, notarizes a DMG with Apple, staples the notarization ticket,
generates a SHA-256 checksum, and publishes both files to GitHub Releases.

The source repository may remain private. In that case, only GitHub users with
repository access can download its release assets. A public product can use the
same signed DMG from a public binary-only repository or a separate download
site without making this source repository public.

## One-time Apple setup

1. Join the Apple Developer Program and create a **Developer ID Application**
   certificate for direct distribution. The Raycast integration pins the
   current signing Team ID, `434X69L4Z5`; changing teams requires a reviewed
   source update before packaging a release.
2. Export the certificate and private key from Keychain Access as a password-
   protected `.p12` file.
3. In App Store Connect, create an API key that can submit software to Apple's
   notary service. Download its `.p8` file and record the key ID and issuer ID.
4. Do not commit the `.p12`, `.p8`, passwords, or their Base64 values.

## Required GitHub release controls

Create a GitHub Actions environment named **`macos-release`** before the first
release. Configure all of the following outside the repository:

1. Add required reviewers who are allowed to approve a signed release, prevent
   self-review, and restrict the environment to tags matching
   `agent-tooling-app-v*`.
2. Protect the repository's default branch (normally `main`) so changes reach
   it only through the approved review and validation path.
3. Add a repository ruleset for `agent-tooling-app-v*` that restricts tag
   creation to release managers and prevents tag updates and deletion. The
   workflow rejects lightweight tags, but GitHub's ruleset is what protects who
   may create, replace, or delete the annotated tag object.
4. Create the repository Actions variable **`MACOS_RELEASE_ALLOWED_ACTORS`** as
   a comma-separated list of exact GitHub login names permitted to push a
   release tag. Both the original workflow actor and a rerun's triggering actor
   must be in this list.

The workflow first runs a secret-free authorization job. It peels the annotated
tag to a commit and requires that commit to be an ancestor of the freshly
fetched default branch. Only then can the `macos-release` environment approval
unlock the signing/notarization job. Branch ancestry authorizes the source
commit; it does **not** authorize the separate tag object or its creator. The
actor allowlist, immutable tag ruleset, and environment review cover that
separate authority boundary.

## Required GitHub Actions secrets

Configure these as **environment secrets** on `macos-release`, not as general
repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_NOTARY_KEY_BASE64` | Base64-encoded App Store Connect `.p8` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

The files can be encoded locally without printing them into shell history:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
gh secret set MACOS_CERTIFICATE_P12_BASE64 --env macos-release --repo adalloul0928/agent-tooling

base64 -i AuthKey_KEY_ID.p8 | pbcopy
gh secret set APPLE_NOTARY_KEY_BASE64 --env macos-release --repo adalloul0928/agent-tooling
```

Paste the clipboard value when `gh` prompts. Set the remaining secrets with the
same `gh secret set NAME --env macos-release --repo
adalloul0928/agent-tooling` form. After verifying the environment copies,
remove any repository-scoped copies of these five secrets; otherwise a workflow
revision that does not declare `macos-release` could still receive them.

## Publish a release

An approved annotated tag is the final release request. App tags are namespaced
so they do not collide with the repository's plugin history. Start from an
up-to-date protected default branch, and do not use a lightweight tag:

```sh
git tag -a agent-tooling-app-v0.1.0 -m "Agent Tooling 0.1.0"
git push origin agent-tooling-app-v0.1.0
```

The tag triggers `.github/workflows/release-macos-app.yml`. The release is not
given access to environment secrets unless the tag actor is allowlisted, the
annotated tag still identifies the authorized tag object, its peeled commit is
on the protected default-branch history, and the environment review is
approved. It is not published unless tests, Developer ID verification,
notarization, stapling, and Gatekeeper assessment all pass.

## Install from a private release

Authorized GitHub users can download the newest DMG from the repository's
Releases page or with the GitHub CLI:

```sh
gh release download --repo adalloul0928/agent-tooling --pattern '*.dmg'
open Agent-Tooling-*-arm64.dmg
```

Open the DMG and drag **Agent Tooling** into **Applications**. Xcode, Swift, and
a local repository clone are not required on the destination Mac.

## Scope of the first release channel

- Apple Silicon only
- macOS 26 or newer
- Direct Developer ID distribution
- Manual updates through GitHub Releases

Automatic updates and a Homebrew Cask should be added after the signed alpha
has been installed and exercised successfully on a second Mac.

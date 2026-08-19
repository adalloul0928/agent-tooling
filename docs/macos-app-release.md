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
   certificate for direct distribution.
2. Export the certificate and private key from Keychain Access as a password-
   protected `.p12` file.
3. In App Store Connect, create an API key that can submit software to Apple's
   notary service. Download its `.p8` file and record the key ID and issuer ID.
4. Do not commit the `.p12`, `.p8`, passwords, or their Base64 values.

## Required GitHub Actions secrets

Configure these repository secrets under **Settings → Secrets and variables →
Actions**:

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
gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo adalloul0928/agent-tooling

base64 -i AuthKey_KEY_ID.p8 | pbcopy
gh secret set APPLE_NOTARY_KEY_BASE64 --repo adalloul0928/agent-tooling
```

Paste the clipboard value when `gh` prompts. Set the remaining secrets with the
same `gh secret set NAME --repo adalloul0928/agent-tooling` form.

## Publish a release

The tag is the release authority. App tags are namespaced so they do not collide
with the repository's plugin history:

```sh
git tag -a agent-tooling-app-v0.1.0 -m "Agent Tooling 0.1.0"
git push origin agent-tooling-app-v0.1.0
```

The tag triggers `.github/workflows/release-macos-app.yml`. The release is not
published unless tests, Developer ID verification, notarization, stapling, and
Gatekeeper assessment all pass.

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

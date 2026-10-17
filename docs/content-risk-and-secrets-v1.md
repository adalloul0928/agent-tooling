# Content risk and the secrets boundary v1

Status: implemented.

## Purpose

Two controls keep review honest. `ContentRiskScanner` inspects a package tree
before install and surfaces anything that would make the reviewed text differ
from what runs, so a person approves what they actually read. `ResponseRedaction`
is the last sweep over every MCP response, a backstop for the rule that the
portable document and the MCP surface carry no secret value and no device path.

## The model

`ContentRiskScanner.scan` (`ContentRiskScanner.swift`) returns a
`ContentRiskReport`: `findings`, `filesScanned`, `coverageNotes`, and
`reachedScanLimit`. A `ContentRiskFinding` has a `ContentRiskCategory`, a
`ContentRiskSeverity`, a package-relative path and optional line, a headline, a
bounded redacted `evidence` excerpt, and guidance. Severity is `risky`
(legitimate in many packages, worth a look) or `malicious` (no honest
explanation in a skill or plugin). A report `isClean` only when it is complete:
`reachedScanLimit` turns a clean-looking result into an explicit partial answer.

`ResponseRedaction` (`AgentToolingMCP/ResponseRedaction.swift`) rewrites every
string leaf of a `JSONValue` result through `redactedText`.

## Behaviour

The scanner walks the tree within bounds (`Limits`: files, per-file bytes, total
bytes, lines, findings) and never throws. It:

- reports hidden Unicode: zero-width characters, bidirectional overrides,
  Unicode Tag-block characters (decoded when printable), and runs of variation
  selectors, the overrides and smuggling carriers rated `malicious`;
- reports prompt injection by pattern: override-earlier-instructions, role
  overrides, forged system-prompt markers, instructions to hide work from the
  person or act without asking (`malicious`), and moving credentials off the Mac
  (`malicious`, gated on a companion exfiltration verb);
- reports remote dependencies: `curl|wget | sh`, plain HTTP, bare-IP and
  shortened URLs, unpinned downloads (cleared by a checksum or signature), and
  installs straight from a URL;
- reports executable content: a `#!` shebang and the executable permission bit;
- rates a symlink `risky` because it leaves the reviewed tree.

A directory it excludes for cost (`.git`, `.build`, `node_modules`, `.venv`), a
file too large or not valid UTF-8, a line past the length or count bound, or an
enumeration error each sets `reachedScanLimit` and adds a coverage note. It
never removes, rewrites, or filters content: a review-first app that silently
dropped a file would misstate what the person approved.

`ResponseRedaction.redactedText` caps length, replaces control characters,
returns `[secret withheld]` when a value carries a secret marker
(`containsSecretMarker`: auth headers, bearer, common key prefixes, a URL with
embedded credentials), and replaces path-bearing tokens with `[path withheld]`
(`containsFileSystemPath`: the literal home directory, `~/`, or a leading `/`).

## The portable-document secrets invariant

The portable document carries secret *reference names* only, never secret
values, and no device path or credential reference. Connection records hold
`secretReferenceNames` (validated identifiers), and the MCP surface returns
those names, never values. Device-specific state (observations, locations,
tool directories) stays on the Mac's own device record, outside the portable
document. The sync encryption key lives in the Keychain alone and never travels
in the document.

## Safety boundary

The scanner reads a package tree and reports; it writes nothing and makes no
network call. `ResponseRedaction` is construction's assertion, not its
replacement: MCP responses are already built from an allowlist of fields, and
every string leaf is swept anyway because a transcript is forwarded to a model
provider. Object keys are left alone, because they are this target's own
literals rather than workspace content.

## What the UI shows

The content-risk report shows beside the Run or approve button in the install
and review surfaces (Apps, Discover); a partial report says so rather than
reading as clean.

## Tests

- `ContentRiskScannerTests.swift` — each category, the severity ratings,
  companion and cleared-by gating, the bounds, and the partial-report semantics.

MCP response redaction is pinned by the AgentToolingMCP disclosure tests
(`ReadOnlyDisclosureTests.swift`).

## Not covered

The scanner is pattern and structure based, not a semantic analysis of what a
script does; it reports for review rather than deciding. It does not scan a
client's own already-installed content, only a package before install.

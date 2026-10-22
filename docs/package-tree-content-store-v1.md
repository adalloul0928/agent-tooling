# Package tree and central content objects v1

This is the additive S3 storage primitive and part of AP4's complete-package
preservation work. It does not switch the application library, import a live
setup, install content into a client, establish upstream ownership, or make a
native plugin portable. The workspace revision service and later operation
journal must authorize and record those changes.

## Captured content

`CapturedPackageTree` contains a validated, immutable list of directories, files
and relative symbolic links. File bytes are exact; the executable flag is
preserved. Empty directories and hidden files, native adapter manifests,
scripts, assets, references and unknown extension files remain part of the tree.
The root directory itself is implicit. No frontmatter rewrite or standalone
skill wrapper is performed.

Only the exact root `.git` administration entry is omitted during source
capture. The result records that omission as a local observation. Nested `.git`
entries are rejected rather than silently removed. A stored content object may
not contain even a root `.git` entry; object verification rejects it.

Paths and link targets use NFC Unicode. Paths must be relative, nonempty and
free of control characters, backslashes, empty components, `.` and `..`.
Case-insensitive or Unicode-equivalent entry collisions are rejected for
portable deployment. Every parent directory is explicit. Link targets may use
`.` and `..`, but component-by-component resolution must remain inside the
captured tree. Escaping, dangling, cyclic and file-as-directory links are
rejected. Links are stored as links; their targets are not traversed during
capture. Paths are not URL-decoded or shell-expanded.

Default bounds are 10,000 entries, 32 MiB per file, 128 MiB total file bytes,
64 directory levels and 4,096 UTF-8 bytes per relative path/link target.
Capture performs blocking filesystem work in a detached task and propagates
cancellation. Directory enumeration is bounded. Special files such as FIFOs,
sockets and devices are rejected without reading them.

Descriptor-relative, no-follow traversal checks entry identity, type, mode,
size and modification/change times before and after reading. Directory names
are enumerated again, and a final metadata pass revalidates captured entries.
The URL API also rechecks the root pathname binding. The internal descriptor
API duplicates its caller's directory capability and does not close the caller's
handle; the content store independently validates its root/object bindings.

These checks detect ordinary concurrent edits and replacement races. They are
not a filesystem snapshot or a security boundary against another process with
the same user's permissions. An attached, actively edited authoring folder
still needs a fresh reviewed capture before a later deployment.

## Exact `sha256TreeV1` digest

The SHA-256 preimage is constructed in this order:

1. UTF-8 bytes of `agent-tooling.package-tree.v1` followed by a zero byte.
2. Entry count as an unsigned 64-bit big-endian integer.
3. Entries in lexicographic order of their NFC path's UTF-8 bytes. Each entry is:
   - Path byte count as UInt64 big-endian, then path bytes.
   - One kind byte: ASCII `d`, `f` or `l`.
   - Directory: no additional payload.
   - File: one executable byte (`0` or `1`), UInt64 big-endian byte count, then
     the exact file bytes.
   - Link: UInt64 big-endian target byte count, then NFC target UTF-8 bytes.

The resulting value is 64 lowercase hexadecimal characters. File payloads are
not Unicode-normalized. Modification times, ownership, ACLs, extended
attributes, full permission modes and root Git omission observations are not
part of this digest or this content representation. Export compatibility must
report any unsupported required metadata rather than claim a full filesystem
archive.

The independent golden fixture for `assets/`, `assets/a.txt` containing `A`,
`latest -> assets/a.txt`, and executable `run.sh` containing `#!/bin/sh\n` is
`e6505517f35988dd1bd550acf7b6f4ae38617f00a38b59d891012defcdb99dc1`.

Git revisions/tree IDs, Vercel project folder hashes, provider integrity strings
and the legacy directory fingerprint keep their existing algorithm identities.
None can be relabeled as `sha256TreeV1` without a new complete-tree capture.

## Immutable object store

`CentralPackageContentStore` is a Swift actor. Its initializer accepts an
existing private directory owned by the current user. An empty directory can
be initialized; a nonempty root must contain the exact known format marker and
only the expected store entries. Unsupported or damaged markers are rejected.
A nonblocking advisory lock serializes cooperating initializers. Contention
returns `busy` without modifying the store; callers can retry asynchronously.

The local layout is:

```
format                              # agent-tooling-content-store.v1\n
objects/<sha256TreeV1>/payload/...   # published complete trees
staging/<random-id>/payload/...     # unpublished writes
```

The store holds directory descriptors, verifies root/objects/staging identity
and privacy on every operation, and rechecks the marker. Child operations use
`openat` and no-follow behavior; replacing a pathname cannot redirect a write to
a different directory.

Intake revalidates the tree under store limits, writes a private stage, flushes
file bytes and directories, protects the payload from accidental writes, and
captures the stage again to verify its digest. A no-replace atomic rename
publishes the whole object. The wrapper is protected immediately afterward:
macOS requires it to remain writable during the rename. Files/directories use
owner-only modes: directories and executable files `0500`, other files `0400`.
These modes provide cooperative immutability, not protection against the owner
intentionally changing permissions.

Concurrent publication of the same digest verifies and reuses the winning
object. Existing corruption is reported rather than repaired or overwritten.
Reading verifies the entire tree and object bindings before returning bytes.
Older objects remain available; this primitive has no garbage-collection API.

A failed pre-publication operation removes only its still-bound private stage.
Cancellation or failure after the atomic rename may leave a complete,
unreferenced object. Process termination may leave an unpublished stage or a
published wrapper still at `0700`; its payload must still pass full verification. No
workspace pointer has changed in either case. Recovery/retention policy must
reconcile these objects through the future filesystem/database journal; this
module does not claim cross-store transactional recovery or power-loss proof.

## Integration still required

- S3 [personal/upstream intake and central update commands](central-skill-intake-v1.md)
  now reference verified objects with durable workspace/source metadata. Reviewed
  destination update plans and active GUI/CLI integration remain open.
- D2 legacy inventory/materialization mapping and an explicit migration preview,
  raw checkpoint, assignment parity and rollback.
- D3/Y2 operation receipts and filesystem/database recovery, including cleanup
  ownership, crash injection and safe retention of referenced content.
- AP4 package intake/staging/export round trips and AP3 native compatibility.
- Destination freshness checks and preservation of modified deployments before
  any client files are changed.

The module's unit tests use temporary directories only. They do not qualify
native consumption, packaged app performance, cloud export or two-Mac sync.

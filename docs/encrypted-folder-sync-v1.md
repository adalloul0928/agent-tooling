# Encrypted folder sync — contract v1

Status: implemented and fixture-tested on one machine. No two-Mac run.

## What it is

A second transport for the same sync lifecycle. Instead of a private Git
repository, revisions travel through a folder that a file-sync service already
keeps in step between a person's Macs — iCloud Drive, Dropbox, a network share.

What lands in that folder is a sealed box (AES-GCM) plus a tiny plaintext
envelope carrying the format version. The portable document — every item name,
every destination, every project name — is never written there in the clear.

## Why a second transport rather than a second sync engine

`WorkspaceRevisionTransport` has exactly two methods: observe what is there, and
publish on top of exactly what was observed. Merging, conflict decisions,
ancestry and commit ordering all stay in `WorkspaceSyncCoordinator` and
`WorkspaceMergeEngine`, which both transports share unchanged. A transport that
could merge would be a second set of merge rules to get subtly wrong.

`head` is opaque to the coordinator. Git returns a commit; the folder returns the
SHA-256 of the sealed bytes. It is only ever compared for equality and handed
back, so the two are interchangeable.

## Concurrency

Publishing is compare-and-set on that digest, checked twice: once before sealing
and once immediately before the file is moved into place. A Mac that finds
something other than what it expected reports `remoteAdvanced` with what it
found, and the coordinator merges rather than overwriting.

The sealed box is written to a `.partial` file in the same folder and moved into
place, so a sync service never uploads a half-written box.

## The key

The key is random, 256-bit, generated on the first Mac. It is **not** derived
from a passphrase: a passphrase a person would actually remember is a poor key,
and this build has no password hashing worth trusting for one.

Setting up a second Mac moves the key itself, shown once as a recovery phrase in
Crockford base32 — the ten digits and the letters except `i`, `l`, `o` and `u`,
in groups of five. Reading a phrase back ignores case, spacing and dashes, and
reads `o` as `0` and `i`/`l` as `1`, because someone copying it off another
screen should not be defeated by the shape of a character.

The phrase is shown once and is not stored anywhere it could be shown again.

## What this protects, exactly

**It protects the library from the sync service** and from anyone else who can
see the folder's contents. That is the threat a plain shared folder has and a
private Git repository mostly does not.

**It does not protect the library from someone who can read the Mac.** The key
is stored in `folder-sync-key.json` beside the workspace database, `0600`,
readable by the account that owns it. The app states this rather than implying
more.

Disconnecting removes the key from that Mac. The folder is left exactly as it is
and stays readable by any Mac that still holds the phrase.

## Failure rules

- A folder that does not exist is refused, never created. A mistyped path should
  not quietly become a new sync location.
- A folder holding a workspace this key cannot open is refused at connect time
  and at every read. A wrong key is never a reason to publish over what is there.
- A key file this build cannot read is an error, never "no key" — treating it as
  absent would generate a new key and seal the folder against every Mac already
  using it.
- An enrollment file records which transport it is. Files written before that
  field existed are Git, which is the only kind that existed then.

## Not covered

No two-Mac run over a real sync service. Nothing here has been tested against
iCloud Drive's or Dropbox's own conflict behavior — a service that renames a file
on conflict rather than replacing it would appear to this transport as a folder
whose head did not change, and that case is unverified. That is the first thing
a two-Mac pilot should look at.

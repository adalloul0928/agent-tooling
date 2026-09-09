# Project declaration and lock — contract v1 (P1)

Status: implemented and fixture-tested, with a Projects surface. No packaged
pilot.

## Two files, on purpose

`.agent-tooling/project.json` — the **declaration**. What this project asks for,
by name, kind, source and requested ref. This is what a person edits and what a
diff should be readable in.

`.agent-tooling/project-lock.json` — the **lock**. What those resolved to, by
immutable revision and content digest. This is what makes a checkout later
reproduce the same bytes.

Keeping them separate is the point. A requested ref is allowed to move; that is
what a branch is for. The lock is what does not move.

## Only a commit hash is a lock

A lock entry must carry a `gitCommitSHA1` (40 hex) or `gitCommitSHA256` (64 hex)
revision. A semantic version is refused because a tag can be re-pointed, and an
opaque publisher revision is refused because it makes no immutability promise
this build can check. Neither would restore the same bytes later, which is the
only thing a lock is for.

The requested ref is kept **beside** the revision rather than replaced by it.
What was asked for and what it turned out to be are different facts, and losing
the first makes the lock impossible to explain.

An item the workspace holds without an immutable upstream revision still appears
in the declaration — it is genuinely something the project asks for — and is
named as unpinned. Writing a lock line that could not restore the same bytes
would be worse than leaving it out silently, and leaving it out silently would be
worse than saying so.

## Additive, and committable

Agent Tooling writes these two files and nothing else. A file at either path
without this app's own `marker` belongs to someone else and is refused — checked
**before** anything is written, so a foreign file next to ours never leaves the
pair half-updated. Other tools' lock files are read elsewhere and never rewritten.

Neither file carries an absolute path, an observation timestamp, a device
identity or a credential; a source address must be credential-free HTTPS with no
query, and a package path must be relative and contained. Encoding is
deterministic — sorted keys, sorted entries, a trailing newline — so the same
inputs produce byte-identical output and a commit diff shows only real changes.

## Reading one back

`WorkspaceProjectDeclarationReconciliation` compares a committed declaration and
lock against what a workspace actually holds, matching on the name an item goes
by and its kind — workspace identifiers are per-workspace and mean nothing in a
file another Mac reads. Each declared item comes back in one of four states:

| State | Meaning |
| --- | --- |
| `matchesLock` | Held, at the exact revision the lock pins |
| `differsFromLock` | Held, but at a different revision than the lock pins |
| `heldUnpinned` | Held, and nothing is pinned to compare against |
| `missing` | Not in this workspace at all |

"Fully satisfied" requires every item to be `matchesLock`. An unpinned item keeps
it false, because *we cannot tell* is not the same answer as *yes*. An empty
declaration is not satisfied either — it asked for nothing, which is not the same
as having everything.

This is read-only and installs nothing. Answering "what does this project want,
and what do I have" is a different act from getting it, and getting it goes
through the ordinary reviewed paths.

## Not covered

No packaged pilot has exercised the flow, and no lock has been used to reproduce
a checkout on a second machine — that is the gate this format exists to pass and
it has not run. Nothing acts on a reconciliation result: there is no "get what I
am missing" button, and adding one would be an ordinary assignment flow rather
than anything new here.

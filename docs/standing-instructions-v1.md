# Standing instructions and agents — contract v1

Status: read-only inventory, implemented and fixture-tested. Locations taken
from each vendor's own documentation, recorded below so a stale one can be
rechecked rather than argued about.

## Recorded locations

**Claude Code** — [instructions](https://code.claude.com/docs/en/memory),
[agents](https://code.claude.com/docs/en/sub-agents)

| Kind | Scope | Location |
| --- | --- | --- |
| Instructions | Managed policy (macOS) | `/Library/Application Support/ClaudeCode/CLAUDE.md` |
| Instructions | User | `~/.claude/CLAUDE.md` |
| Instructions | Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` |
| Instructions | Local | `./CLAUDE.local.md` |
| Rules | User / project | `~/.claude/rules/**/*.md`, `.claude/rules/**/*.md` |
| Agents | User / project | `~/.claude/agents/**/*.md`, `.claude/agents/**/*.md` |

All discovered instruction files are **concatenated**, not overridden.

**Codex** — [AGENTS.md](https://developers.openai.com/codex/guides/agents-md)

In the Codex home (`~/.codex`, or `CODEX_HOME`), the first **non-empty** of
`AGENTS.override.md` then `AGENTS.md`. From the project root down to the working
directory, each directory contributes the first non-empty of
`AGENTS.override.md`, `AGENTS.md`, `TEAM_GUIDE.md`, `.agents.md`. Files are
concatenated root-down.

## The two things this surface exists to say

**They add up.** The same misreading as hooks: a file closer to the project does
not replace one further out. Both clients concatenate.

**The clients read different filenames.** Claude Code reads `CLAUDE.md` and does
**not** read `AGENTS.md`. A project holding only `AGENTS.md` gives Claude Code
nothing, and nothing else in the app would show that — so it is called out by
name when it happens.

## What is deliberately not done

The content is not read, summarised, or interpreted. An instruction file is prose
written for an agent; describing what one "does" would be inventing a claim about
behavior. The inventory reports that a file exists, its scope, its size, whether
it is empty, and opens it on request.

Only a regular file counts, after following links. A directory or a dangling link
where a client expects a file is not an instruction file.

## Not covered

Nothing here is checked against a running client. `/context` in Claude Code is
still the only thing that reports what a session actually loaded; this reports
what is on disk in the places the vendor documents. Nested `CLAUDE.md` files below
the project root, `@path` imports, and path-scoped rule matching are not
resolved — they are load-time behavior, not a fact about the filesystem.

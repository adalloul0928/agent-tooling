---
name: <kebab-case-name-matching-the-directory>
description: >-
  <What it does, in one sentence.> Use when <the phrasings the user would
  actually type>. <What it produces or changes.> <Optional: explicitly when NOT
  to use it, if a near neighbour exists.>
---

# <Title Case Name>

<One or two sentences: what problem this solves, and the shape of the answer.
Lead with the thing a reader needs to know before the steps make sense.>

<Optional but high value — an anti-goal. State the tempting wrong approach and
why it fails, before the reader tries it. The existing skills in this repository
do this and it is what makes them hold up months later.>

## <Mental model / Before you start>

<Only if the steps need shared vocabulary or a decision table first. Cut this
section if the steps stand alone.>

| <Situation> | <What is true> |
|---|---|
| | |

## Step 1 — <verb phrase>

<Imperative instructions. Say what to do, and what "done" looks like.>

## Step 2 — <verb phrase>

<Where a step can fail in a way that is hard to notice, say so inline — silent
failures deserve more words than loud ones.>

## <Failure modes / Gotchas>

<Concrete traps, each with the symptom that identifies it. "X looks like it
worked but Y" is the most useful shape.>

## <When not to use this>

<Neighbouring capability that is the better answer in some cases, and how to
tell which case you are in.>

---

Authoring reminders — delete this block before committing:

- `name` must equal the directory name; frontmatter carries only `name` and
  `description`.
- The description is the trigger surface, and it is loaded into every session.
  Make it specific and include the negative case.
- Never hard-code a client's installation or configuration directory. Describe
  it in capability terms.
- Reference bundled files relative to the skill root: `references/x.md`,
  `scripts/x.sh`, `assets/x`.
- Never reference anything outside the bundle.
- No secrets, tokens, or machine-specific absolute paths.
- Bundled shell scripts are syntax-checked and bundled Python is compiled by
  validation; keep them runnable.

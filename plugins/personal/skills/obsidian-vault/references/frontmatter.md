# Frontmatter Conventions

Use top-of-file YAML frontmatter for new notes only, unless the user asks to normalize existing notes.

## Base Fields

```yaml
---
title: "Title"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
type: note
status: draft
tags: []
aliases: []
---
```

## Field Meanings

- `title`: Human-readable title, usually matching the filename.
- `created`: Creation date in `YYYY-MM-DD`.
- `updated`: Last meaningful edit date in `YYYY-MM-DD`.
- `type`: `note`, `project`, `research`, `meeting`, `decision`, `runbook`, `plan`, or `idea`.
- `status`: `draft`, `captured`, `active`, `review`, `archived`, `done`, or `reference`.
- `tags`: YAML list of lowercase tags without `#`.
- `aliases`: Alternate names for Obsidian lookup.
- `project`: Optional project key such as `PUMPD`, `Harstem`, `IAWIS`, or `jimmy-wedding`.
- `area`: Optional area such as `Tasks / Todo`, `AI Tooling`, `Deployment`, or `Personal`.
- `related`: Optional wikilink list.
- `sources`: Optional source URL/list for research notes.

## Project Note

```yaml
---
title: "Title"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
type: project
status: active
tags:
  - project
project: "PUMPD"
area: "Tasks / Todo"
aliases: []
related: []
---
```

## Research Note

```yaml
---
title: "Title"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
type: research
status: draft
tags:
  - research
project: "PUMPD"
sources: []
related: []
---
```

## Decision Note

```yaml
---
title: "Title"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
type: decision
status: active
tags:
  - decision
project: "PUMPD"
area: ""
decided: "YYYY-MM-DD"
review_after: ""
related: []
---
```

## Idea Note

```yaml
---
title: "Title"
created: "YYYY-MM-DD"
updated: "YYYY-MM-DD"
type: idea
status: captured
tags:
  - pumpd
  - idea
project: "PUMPD"
area: "Tasks / Todo"
source: "user"
related: []
---
```

## Naming

- Prefer Title Case filenames for human-facing notes.
- Keep existing legacy filename style when editing old notes.
- Use wikilinks for vault notes: `[[PUMPD Deployment]]`.
- Use Markdown links for external URLs.

# Control-center mockups

Every design generation for the Agent Tooling macOS app, oldest first. Earlier
generations were produced as published pages rather than files; the HTML for
those is archived under [`archive/`](archive) so the work survives independently
of the hosting.

Open an archived file directly in a browser — each one is a self-contained page.

## Generations

| Date | Generation | Where it lives |
| --- | --- | --- |
| 9 Aug 2026 | **Glasshouse concepts** — first pass at the glass direction | [`archive/glasshouse-v1-concepts.html`](archive/glasshouse-v1-concepts.html) |
| 9 Aug 2026 | **Glasshouse v2** — full screen set | [`archive/glasshouse-v2-screens.html`](archive/glasshouse-v2-screens.html) |
| 9 Aug 2026 | **Glasshouse v3** — intermediate revision | Published page only; no local copy was captured |
| 9 Aug 2026 | **Glasshouse v4, Liquid Glass** — the direction that stuck | [`archive/glasshouse-v4-liquid-glass.html`](archive/glasshouse-v4-liquid-glass.html) |
| 18 Aug 2026 | **Glass Control Room** and **Apple Glass v2** PNG sets | [`overview.png`](overview.png), [`skills.png`](skills.png), [`mcps.png`](mcps.png), [`plugins.png`](plugins.png), [`create.png`](create.png), [`apple-glass-v2/`](apple-glass-v2) |
| 31 Aug 2026 | **Design canvas, "Agent Tooling for Mac"** — 13 artboards, fresh information architecture, coherent sample data | [`archive/design-canvas-2026-08-31.html`](archive/design-canvas-2026-08-31.html) |
| 2 Sep 2026 | **Agent Tooling Tahoe** — the synthesis that was built. 11 screens, light and dark, plus the written design system | [`tahoe/`](tahoe) |

`tahoe/design-system.md` is the authoritative record of the palette, type,
row grammar, and the tokens the app itself uses. Start there rather than
reverse-engineering colours from a PNG.

## Notes on the archive

- The Glasshouse pages and the design canvas were authored as standalone HTML.
  The copies here have the host's runtime wrapper stripped; the page content is
  unchanged.
- `design-canvas-2026-08-31.html` is around 3 MB because every artboard's imagery
  is embedded in the file. That is deliberate — it means the canvas opens with no
  network access and no missing assets.
- Glasshouse v3 was superseded within the same session and only its published
  page exists. It is listed for completeness rather than because anything depends
  on it.

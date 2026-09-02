# Agent Tooling Tahoe — design pass 3

High-fidelity mockups for the native macOS 26 control center, in HTML so the
material, popovers, and both appearances can be inspected directly.

- `index.html` — the full gallery: eleven screens with a Light/Dark switch,
  per-screen notes, and a SwiftUI hand-off section. Self-contained; open it on
  a Mac so SF Pro renders.
- `*-light.png` / `*-dark.png` — 1× renders (1320×860) of every screen for quick review.
- Published copy: see the artifact link in the pull request or session notes.

## Why a third pass

Each earlier pass got one thing right and lost another:

| Pass | Kept | Lost |
| --- | --- | --- |
| Glasshouse v2–v4.1 (Aug 9) | Real translucency, colour identity tiles, icon vocabulary, paths hidden behind ⓘ | A settled information architecture; some SaaS density |
| Glass Control Room / apple-glass-v2 PNGs (Aug 18) | Native controls, restraint, the source → profile → targets idea | The rainbow desktop overwhelmed the window; KPI cards read as generated SaaS |
| Design canvas (Aug 31) | Fresh IA, one state language, sample data that agrees with itself | Glass, colour, icons; screens were grey, text-heavy, and flat |

This pass keeps the canvas's IA and world, restores the Glasshouse material and
identity system, and executes both at macOS 26 quality.

## Subject and job

One technical operator managing Claude Code, Codex, and Gemini CLI from one
Mac. Every screen must answer: what is installed, do the clients agree with the
profile, what needs me, and what changed after an action.

## Visual system

**Material.** One glass sheet. The window and its sidebar blur the desktop
(behind-window material); the content pane is a 90% "paper" inset by 8pt with
a concentric 14pt radius so rows stay crisp. Sheets are a deeper frost over a
dimmed window. Nothing else is translucent.

**Desktop.** A calm four-hue wallpaper (sky, lavender, peach, mist teal in
light; navy, indigo, plum, deep teal in dark). It exists so the glass has
something to refract; it never competes with content.

**Colour = identity, glyph = status.**

| Role | Light | Dark |
| --- | --- | --- |
| Skill tile | `#FF8A1F` | `#FF9D45` |
| Plugin tile | `#B457F0` | `#C77DFF` |
| MCP server tile | `#22A6C9` | `#4CC4E3` |
| Profile tile | `#5E5CE6` | `#7D7BFF` |
| Selection / primary action | `#0A6BE0` | `#0A84FF` |
| OK / attention / error glyphs | `#2EA44F` / `#DB8B00` / `#DE4A3F` | `#3BD160` / `#FFB224` / `#FF5C54` |

Tiles say what a thing is. The three brand marks (the SVGs already in the app's
asset catalog) say where it runs; a dimmed mark means "not available here".
Green, amber, and red appear only as small glyphs beside a label, never as a
tile, a pill, or a bare dot.

**Type.** SF Pro through the system stack: 13pt rows, 11.5pt secondary, 15pt
window titles, one 19pt name per screen. SF Mono only for revisions, tool
names, and commands. Sentence case everywhere.

**Row grammar.** Tile · name · one clause · verdict. Descriptions are one
clause. File locations are never in a row: an ⓘ button opens a popover with the
path and a Reveal in Finder link.

**Controls.** Tahoe capsules: 28pt buttons and pop-ups, a capsule segmented
control whose segments carry the kind tiles (so it doubles as the legend), and
a 20pt window radius.

**Signature.** The Overview conduit draws library → profile → clients as one
path. The trunk animates only while a plan is pending (and never under Reduce
Motion); each terminal carries that client's verdict.

## Screens

Overview · Library · Skill · MCP Servers · Discover · New Skill (sheet) ·
Sync Review · Activity · Claude Code (client page) · Recommendations ·
Settings (own window). Every screen renders in light and dark from the same
markup.

## One world

The sample data is consistent across screens: plan S-118 applied yesterday
(receipt R-208, backup B-142), six changes pending for S-119 with backup B-143
to come, Sentry sign-in expired Thursday, a hand edit in Codex settings held
out of Sync, developer-workflows update waiting, 14 managed and 2 discovered
items, Claude Code 2.1.47 / Codex 0.52.3 / Gemini CLI 0.9.2.

## Applied to the app

The SwiftUI app under `apps/agent-tooling-macos` now implements this system
while keeping its existing sections and routes:

- `Theme.swift` — identity and status colours as dynamic light/dark values, the
  behind-window glass background, the paper pane, card, and row-selection
  modifiers, and a group-box style that puts titles above cards.
- `Components.swift` — `KindTile`, `ClientMarks`, `ClientDisc`, `StatusGlyph`,
  `StatusBadge`, `AttentionBanner`, `TitledCard`, `InfoRow`, `TagCloud`,
  `LocationText` with its ⓘ popover, and the capsule `PageToolbar`.
- `SidebarView.swift` — three groups (untitled, Manage, Operations) and a
  Clients block with one verdict per client from `ClientVerdict.swift`.
- `AmbientBackdrop.swift` — the four-hue desktop from the mockups painted
  inside the window as a slowly drifting mesh gradient, so the glass sidebar
  refracts the same atmosphere on any Mac; the sidebar is a scrim over it.
- `SyncConduitView.swift` — the Overview conduit. The path draws itself in when
  the screen appears, the trunk and any attention branch flow while items need
  attention, terminals lift on hover, and everything holds still under Reduce
  Motion. The sidebar selection slides between rows and counts animate.
- Every collection row uses tile · name · one clause · marks · verdict, with the
  accent selection shape shared with the sidebar; unmanaged items keep the same
  tile at half presence. Paths in detail views sit behind `LocationText`; the
  plan review sheet keeps exact paths on purpose.

## Hand-off to SwiftUI

- Window and sidebar: the existing `DesktopGlassBackground`
  (`NSVisualEffectView`, behind-window) at full strength rather than 0.96
  opacity; sidebar rows on `.glassEffect()`.
- Paper: `RoundedRectangle(cornerRadius: 14, style: .continuous)` filled with
  `windowBackgroundColor` at 0.90, inset 8pt.
- Capsules: `.buttonStyle(.glass)` / `.borderedProminent` with
  `.buttonBorderShape(.capsule)`.
- Tiles: SF Symbols `doc.text`, `puzzlepiece.extension`, `server.rack`,
  `slider.horizontal.3` on 8pt rounded fills of systemOrange, systemPurple,
  systemTeal, systemIndigo.
- Marks: the existing `ClientBrandIcon`, 22% opacity + grayscale when dimmed.
- Status glyphs: `checkmark.circle.fill`, `exclamationmark.triangle.fill`,
  `xmark.circle.fill`, `arrow.up.circle`, always beside a label.
- Popovers: `.popover` from an `info.circle` button with a Reveal in Finder
  link.
- Conduit: a `Path` with a phase-animated dash while a plan is pending, gated
  on `accessibilityReduceMotion`.

## Rebuilding the gallery

`src/` holds the source: `shared.css` (tokens, materials, components),
`sprite.html` (SF-style glyphs and the three brand marks), one fragment per
screen in `src/screens/`, the gallery template, and `build.py`. Running

```sh
python3 src/build.py
```

rewrites `index.html` here and writes standalone light/dark pages for every
screen to `render/` (ignored; handy for screenshots). The PNGs were captured
from those pages with headless Chrome at 1320×860.

# Agent Tooling — Restrained Native Glass

## Subject and job

This is a local macOS control center for one technical operator managing Codex, Claude Code, Gemini CLI, skills, plugins, profiles, and MCP servers. Its single job is to make local state and safe next actions obvious without exposing the user to configuration-file archaeology.

## Why the earlier directions missed

- The old icon-only rail made a complex control plane hard to scan.
- The charcoal pass let the desktop show through, but it did not refract or soften it; foreground text bled into operational content.
- Repeated KPI cards, tiny uppercase labels, and dense table chrome read like generated SaaS convention rather than macOS.
- Icons did not carry a stable object vocabulary across Library, Marketplace, Profiles, and target state.
- The previous composition did not give source → profile → native target state a clear spatial path.

## Visual system

**Color**

- System Blue — `#0A84FF`: selection and primary action only.
- Indigo — `#5E5CE6`, Cyan — `#38B6F0`, Orange — `#FF9500`, Purple — `#B058E0`: small semantic accents for SF Symbols and written lifecycle state, never a decorative rainbow.
- Graphite — `#1A1A21`: primary text. Secondary — `#6E6E73`: supporting text.
- Success — `#2EAD78`; Attention — `#AB7840`: written lifecycle states, never color-only status.
- Desktop substrate — the real macOS content behind the one app window, sampled with `NSVisualEffectView` using behind-window blending. The app adds no gradient, color fog, or artificial backdrop.
- Window glass — the single window is translucent enough to read as glass. Cards, rows, badges, and secondary buttons are not glass: they use standard macOS fills, separators, and native control styles.

**Typography**

- Display and body: the macOS system stack, resolving to SF Pro Display and SF Pro Text.
- Technical evidence: SF Mono through the system monospace stack.
- Display text uses restrained SF Pro scale and weight. Labels use sentence case. SF Mono is reserved for revisions and commands, never general navigation.

**Layout**

The app uses the actual desktop as the substrate for one un-inset native window. macOS's real traffic lights sit at the upper left of that window. A labeled sidebar and an opaque, readable content area share the same shell. The overview is a source → profile → target conduit above attention and receipt groups. Collection screens retain a familiar list-and-inspector anatomy. Creation and plan review appear in standard native sheets above the existing context.

```text
┌ labeled sidebar ─────┬ title · active profile · controls ┐
│ SF Symbol + label    │ local library → profile → targets │
│ selected system blue │ grouped attention │ receipts       │
│ local-state footer   │ collection / inspector on detail   │
└──────────────────────┴─────────────────────────────────────┘
```

**Signature**

The source-to-profile-to-target conduit becomes a single readable spatial path. Small color identity tiles distinguish object kinds, not success states. It is the only expressive custom element; the rest uses quiet macOS controls, grouped rows, separators, and system materials.

## UX changes

- Replace the four-stat-card row with one compact system library.
- Use a readable text sidebar; badges are sparse and count real data only.
- Use familiar SF Symbols with restrained semantic tint; no bespoke glyphs, mascots, wands, decorative AI imagery, or synthetic icon tiles.
- Avoid card-inside-card composition. Use separators for related rows and reserve panels for real functional groups.
- Keep color sparse and semantic; avoid a colored dashboard, generic blue-purple gradient, or translucent control pile-up.
- Keep the primary action in the toolbar and use icon-only controls only for familiar actions.
- Use collection/detail split views for Skills, MCPs, and Plugins.
- Distinguish configured, installed, usable, authenticated, and activated states.
- Present repair commands behind a disclosure instead of making a terminal the dominant visual.
- Create skills in a sheet with a visible automation summary, safety toggles, and one final `Create & Sync` action.
- Keep commands previewable, cancellable, and receipted while the renderer never receives a general shell API.

## Self-critique after render

The render should read as one native glass window—not as a set of floating transparent cards. The desktop is visible only where the window material earns it; operational content stays intentionally more opaque. Contrast is carried by graphite system typography, familiar macOS controls, separators, and spatial separation. System blue is reserved for selection and the primary action; semantic colors stay small and precise. Internal rows use separators instead of nested cards, and every SF Symbol maps directly to an object, action, or status in the tooling workflow.

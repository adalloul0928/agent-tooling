# Design review, September 2026

Three documents produced while reviewing the macOS app against the rest of the
ecosystem. Each is a self-contained HTML page — open it in a browser.

| Document | What it is |
| --- | --- |
| [`agent-tooling-handbook.html`](agent-tooling-handbook.html) | The user guide. Setup, what the app covers and deliberately does not, the eleven screens, project scope, multiple Macs, connectors, the safety model, the CLI, keyboard shortcuts, and edge cases. |
| [`agent-tooling-landscape.html`](agent-tooling-landscape.html) | A scan of 70+ competing and adjacent projects — MCP installers, skill marketplaces, config-sync CLIs, desktop apps, and enterprise gateways — grouped, with links and verified star counts. |
| [`agent-tooling-roadmap.html`](agent-tooling-roadmap.html) | Ranked recommendations drawn from a deep read of the closest tools' source, docs, and screenshots. |

## What the review concluded

**The differentiator is the review-and-receipt discipline, not "manage your
skills."** Across every project examined, none shows a plan of exactly what will
be written and refuses to run when that plan changed after review. Audit trails
exist only in the enterprise gateway tier, as a network product for an
organisation — never as a local record for one person. The Observed / Installed /
Authenticated vocabulary, and the refusal to infer the last one, also appears to
be unique.

**The biggest product gap was the absence of a path from discovered to managed.**
A fresh install could see hundreds of skills already on the machine and do
nothing with any of them, which left the library — the thing every other feature
depends on — empty.

**One security finding shaped the MCP server design.** The `--digest` argument on
`agent-tooling apply` is content integrity, not consent: it proves the plan being
run is byte-identical to the plan someone read, but anyone holding the plan can
compute a valid digest. Exposing `apply` as an agent-callable tool would
therefore hand a prompt-injected agent a self-approval primitive. The roadmap's
proposed server is read-only tools plus queue-a-request tools, over stdio, with
approval staying in the app's own review sheet.

## Provenance

Findings come from reading source, documentation, release notes, and screenshots
rather than marketing pages. GitHub star counts and archive status were verified
against the GitHub API on 2 September 2026. Items that could not be independently
confirmed are marked as such in the documents rather than dropped or asserted.

Related: [`../tooling-control-center-mockups/`](../tooling-control-center-mockups)
holds every design generation these documents refer to.

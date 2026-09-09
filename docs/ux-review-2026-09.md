# Agent Tooling: UX review and redesign

## Native finish revision

The first pass's teal, tinted sidebar, pastel icon tiles, and oversized Home cards were rejected. This revision follows [Apple's Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass): remove custom backgrounds that cover system materials, reserve glass for navigation and controls, and keep content readable.

Direction: native `NavigationSplitView` and sidebar `List`, with the system's `NSGlassEffectView` owning navigation content. Remove the opaque window and custom sidebar backings. A behind-window material sits beneath the native split view; the detail canvas stays neutral and readable. All segmented selectors and filter menus use shared native components.

Palette: porcelain `#F5F5F7`, white `#FFFFFF`, charcoal `#1C1C1E`, raised charcoal `#2C2C2E`, graphite `#6E6E73`, and system Apple blue for actions. Home uses a 32 pt heading, 18 pt recommendation titles, and 15–16 pt descriptions. Remove rounded display lettering and colored secondary-button fills.

The supplied Codex directory screenshots inform the latest refinement: recognizable artwork, short descriptions, quiet two-column rows, and room to read. Home now leads with saved recommendations. The library strip and installed-tool icons provide secondary entry points; routine activity remains in Activity. Original artwork from 24 known tool identities is bundled locally with provenance records. Unknown identities retain neutral SF Symbols.

```text
translucent sidebar │ Home                         (↻) (Review changes)
                    │ Recommended for you
                    │ [icon] Useful skill     [icon] Useful tool
                    │        Short summary          Short summary
                    │ Your library
                    │ ┌───────────────────────────────────────────┐
                    │ │ Skills · 176 │ Plugins · 53 │ Servers · 14│
                    │ └───────────────────────────────────────────┘
                    │ Installed tool icons
                    │ Actionable updates, when present
                    │ Apps found on this Mac
```

## Intent and evidence

Agent Tooling is a native workspace for a person who collects, creates, and maintains capabilities across AI apps. Its primary job is to make it easy to find a useful capability, understand where it comes from and where it is available, and make a deliberate change.

Reviewed the nine supplied screenshots, the running macOS app, all thirteen destinations and their authoring/review flows in source, the package library and source model, navigation contracts, and existing app tests. The starting checkout is `fe36b65735444ab29b783ba2c1892fbb911b87f8`. Findings about third-party products below use their public documentation and published interfaces; they are not installation or runtime validation. Native Codex UI automation is unavailable, so OpenAI research uses its official documentation and product walkthrough.

## Comparable products

| Reference | Evidence and useful pattern | Decision for Agent Tooling |
| --- | --- | --- |
| [Claude Customize and unified directory](https://support.claude.com/en/articles/14328846-browse-skills-connectors-and-plugins-in-one-directory) | One customization area, separate installed lists and discovery, and explicit differences between skills, connectors, and plugins. | Group the installed inventories into Library. Keep their types visible in tabs. |
| [Claude plugins](https://support.claude.com/en/articles/13837440-use-plugins-in-claude) | Published browsing screenshot uses readable cards, short purpose statements, a clear search field, and an install action. The documentation distinguishes installed skills from copies users can edit. | Use a discovery gallery; show source ownership in details and name copying explicitly. Preserve whole-plugin controls. |
| [OpenAI plugins](https://help.openai.com/en/articles/20001256/) | The directory leads to package contents and setup requirements. Underlying app authentication and permissions remain distinct from the plugin. | A package can be installed while its connection still needs setup. Never turn local discovery into an account-connected claim. |
| [OpenAI role-based workflows](https://openai.com/index/codex-for-every-role-tool-workflow/) | Packages are presented around useful work, with related skills and integrations. | Descriptions should explain a capability before provenance or transport. Avoid exposing opaque identifiers as the main identity. |
| [SkillDock](https://github.com/yiwen65/SkillDock) | Published screenshot and README show source repositories, a searchable inventory, detail inspection, and explicit installation destinations. Its Git workspace preserves source ownership. | Retain repository origins and per-app installation evidence. Avoid the permanent detail column and decorative statistics that compete with the inventory. |
| [MCPLinker](https://github.com/milisp/mcp-linker) | Published Discover screenshot separates discovery from management, uses category entry points, and gives each server a short description and a clear action. | Discover gets the full canvas and an optional inspector. Sources become an explicit secondary control. |
| [CC Switch](https://github.com/farion1231/cc-switch) | Published main-interface screenshot makes the selected AI app prominent and uses a simple list. Documentation covers MCP and skills management across clients. | Keep app identity visible and consistent. Do not hide the destination of a change inside an icon-only affordance. |
| [MCPMate](https://github.com/loocor/mcpmate) | Documentation describes progressive configuration, profiles, clients, capabilities, and runtime visibility. | Keep advanced capability controls and testing, but put them inside server details. Do not add proxy/runtime management merely to match another product. |

## Findings

### 1. Navigation describes the implementation more than the user's work

Thirteen equally weighted destinations compete for attention. Connections and Accounts overlap in ordinary language. Configurations and Collections look related but have different consequences. Clients is both a destination and a second sidebar list. Library is present in the data model but absent as the main navigation concept.

Change: Home, Library, Discover, Projects, Configurations, Apps, Insights, Activity, Settings. Library contains Skills, Plugins, Connections, Collections. Apps contains local installations and Accounts. Preserve deep links and command-palette routes to every underlying destination.

### 2. Home spends its attention on infrastructure

The conduit repeats Library and Local Library, describes empty desired state, and leads with a diagram rather than a useful next action. Unknown update provenance appears in the same area as actionable updates. Local checks look like overall health even though cloud access is separate. At a large window size, much of the canvas is unused while dense text remains small.

Change: make “Recommended for you” the main section, using existing saved Insights findings. Keep descriptions short and readable, with direct links to the actual skill or package. A compact library strip, installed tool icons, and meaningful updates follow. Routine activity and unknown update status remain available in their dedicated screens. No scan runs automatically and no personalization is fabricated.

### 3. Discovery opens three columns before the user chooses anything

The source rail, result rail, and automatically selected detail consume most of the window. The install action follows a long stack of review metadata and grading. Alphabetical first selection feels arbitrary. A metadata-completeness grade can be mistaken for a capability or safety rating.

Change: a searchable two-column list of icon-led rows by default, with filters and source management on demand. Selecting a package opens the inspector and switches the browser to compact rows. Put supported installation routes near its purpose and keep source evidence and metadata evaluation in expandable sections with accurate labels. No fabricated recommendations or trust badges.

### 4. Inventories use inconsistent visual and interaction systems

Skills uses custom rows; Plugins and MCP use native striped tables; the latter draws empty stripes through unused space. Search moves around and changes style. Several columns repeat source information; MCP adds unrelated colored chips to nearly every cell. The client marks communicate presence but can be mistaken for live connectivity.

Change: consistent search fields, quiet table backgrounds, legible row rhythm, reduced badge saturation, and a deliberate inspector header. Preserve keyboard selection and multi-selection where supported. Keep the full-width browser until selection. App marks must retain their accessible evidence labels.

### 5. Skill maintenance language is not a user action

“Adopt,” “Not adopted,” and “Automatic” appear before what the skill does. A repo-maintained personal skill appears to need adoption even though it is already installed. Source grouping repeats the marketplace in every group and row. Some summaries are missing: visual design cannot invent descriptions that discovery did not retrieve.

Change: “Copy to library” describes the action. “From a source” and “In your library” describe maintenance. Keep ownership independent. Show the skill's purpose first, app availability next, then source/files. Explain explicitly when a Claude switch controls its entire plugin. Missing descriptions remain a discovery issue to fix independently.

### 6. Insights asks for configuration before showing value

The large configuration form and scan coverage occupy the first screen, pushing recommendations below the fold even when a report exists.

Change: recommendations and findings first. Put scan options in a popover; keep coverage accessible in a disclosure. Preserve the opt-in for catalog queries, cancellation, partial-coverage explanations, and the local-history boundary.

### 7. Advanced capabilities should survive the simplification

Collections support nested membership, tags, import/export, and sharing. Configurations specify desired state. Projects inspect local configuration and support ignore/reveal actions. MCP details include capability controls, live testing, and argument builders. Activity contains receipts and operation outcomes. Settings includes encrypted folder sync, recovery, backup/restore, policy, and client choices.

These are meaningful features. Keep them accessible in their existing flows and restyle their shared surfaces. Do not imply that a collection installs its contents or that a configuration is already applied. Retain preview/apply boundaries and accurate partial outcomes.

## Visual direction

Two concepts were considered:

1. A catalog-first interface with oversized marketplace cards everywhere. Rejected: it treats routine maintenance as shopping and wastes space in a large personal inventory.
2. A native library workspace with calm navigation, editorial page titles, precise inventory rows, and a discovery gallery. Selected: it accommodates both a maintained repo and local skills while retaining dense operational detail when needed.

The signature is the relationship between a capability and the apps that can use it: visible app identity in the library, a compact per-app overview on Home, and destinations close to every change action.

Tokens:

- Charcoal `#1C1C1E`: dark workspace canvas.
- System Liquid Glass sidebar supplied by `NavigationSplitView`; behind-window backing beneath the split view, without a painted sidebar overlay.
- Raised charcoal `#2C2C2E` and white `#FFFFFF`: panels and inputs.
- Porcelain `#F5F5F7`: light workspace canvas.
- System Apple blue: links and primary actions; neutral glass for secondary toolbar actions.
- Original tool artwork identifies recognized packages; graphite SF Symbols identify item types and unknown packages. Status retains its own glyph and label.
- Display: default SF, 32 pt bold for Home, 20–22 pt section headings.
- Body: Home and Discover use 15–16 pt descriptions and 17–18 pt item names; dense inventories retain smaller native control typography.
- Utility: SF Mono for counts, paths, revisions; 11–12 pt captions.
- Navigation: native sidebar selection and row geometry; 230 pt ideal width, resizable from 210 to 300 pt.
- Selectors: one native segmented picker wrapper and one bordered filter-menu style, regular size with capsule shape. Responsive filter groups wrap before clipping.
- Content: 24 pt horizontal rhythm; responsive gallery columns; consistent 36 pt search controls; deliberate 44–56 pt inventory rows.
- Inspectors: closeable, resizable, independently scrollable; no forced empty inspector.
- Motion: short state transitions, respecting Reduce Motion. Surfaces remain legible with Reduce Transparency.

```text
Agent Tooling      Library                         New skill
Search…           Skills  Plugins  Connections  Collections
                  ─────────────────────────────────────────
Home              Search skills…        Ownership / Filters
Library           Name & purpose       Source    AI apps
Discover          …

Workspace         [selection opens a resizable inspector]
Projects
Configurations
Apps              Discover
Insights          Search packages…       Sources / Filters
                  ┌────────┐ ┌────────┐ ┌────────┐
Activity          │Purpose │ │Purpose │ │Purpose │
Settings          │Apps    │ │Apps    │ │Apps    │
                  └────────┘ └────────┘ └────────┘
```

## Implementation and acceptance

Implement the shared visual system, navigation grouping, Home, gallery discovery, consistent inventories, results-first Insights, and supporting screen refinements. Keep portable package storage, client adapters, operation planning, and external account boundaries intact.

Validate: Swift build, focused app/navigation/render tests and the existing core suite as appropriate; live navigation across every destination; inventory filtering and selection; inspector close/Escape; gallery source filtering and detail; authoring sheet open/cancel; narrow and wide native renders in both appearances. Read-only UI checks must not install tools, change app availability, scan private history, or apply sync plans merely for visual proof.

External publishing, Git commits, remote synchronization, and client-install actions are outside this redesign's verification scope.

## Implemented result

- Nine sidebar destinations, with four Library tabs and two Apps tabs. Existing route identifiers remain intact; the command palette finds both new and established screen names.
- Home leads with up to four saved recommendations, larger type, a first-sentence summary, and a direct action. A divided library strip, deduplicated installed-tool icon strip, actionable issues/updates, and compact local-app footer follow. Routine logs, duplicate promotional content, and the all-clear card were removed.
- Discover opens as two columns of icon-led rows with readable names and descriptions. Sources are in a popover; package selection opens a resizable inspector. Installation routes follow the purpose statement, ahead of expandable source and metadata details. Recency sorting retains the update date.
- Twenty-four recognized tool identities use locally bundled original artwork, with appearance-specific files where supplied and exact source-qualified identity matching. Unknown namesakes do not inherit another publisher's logo. Artwork never implies account authorization or trust.
- The sidebar uses native split-view glass and system selection. Shared native segmented controls replace custom underline tabs and competing picker styles throughout Library, Discover, Projects, and other screens.
- Shared page titles, native glass toolbar controls, search fields, inspector headers, neutral identity symbols, stronger primary-action contrast, and matching light/dark surfaces. Appearance moves to the sidebar footer.
- Plugin and MCP tables adapt to narrow panes and stop drawing empty alternating stripes. Compact MCP rows keep status visible; their source/transport filters remain available in a menu. Unknown plugin updates are explained in the inspector without squeezing the title.
- Skills uses “Copy to library,” distinguishes source maintenance from personal ownership, and formats source groups with a readable separator. Classification moves below the skill detail. Closing inspectors retains the full-width browser.
- Insights leads with the saved findings. Scan options move to a popover; coverage and catalog-query outcomes remain in a disclosure. No history scan or client installation was initiated for visual verification.
- Activity now opens details on selection. Settings, Configurations, Projects, Collections, Accounts, and Apps retain their existing features through the shared visual system. Accounts keeps provider authorization distinct from local discovery.

## Verification record

Final commands run from `apps/agent-tooling-macos`:

```sh
WORKSPACE_LAYOUT_CAPTURE="$PWD/.build/ux-renders" swift test --disable-sandbox --scratch-path .build/native
./scripts/package-app.sh
```

The native render coverage produces **68 SwiftUI renders**: every destination at 1180 and 1660 pt widths in both appearances, plus selected Skills, Plugins, MCP, and Discover inspectors at each size/appearance. It uses an isolated store and example data, checks that populated native tables have rows, and verifies that rendering does not create an operation plan. It covers layout, not every interaction or a full accessibility audit. The generated local images are in `apps/agent-tooling-macos/.build/ux-renders/`.

Review caught a Discover regression that retained two columns beside an inspector. The browser now changes to one compact column when details open; that state is included in the render matrix. Shared selector checks cover stable selection geometry, narrow Discover controls, and long labels. Artwork tests check qualified identity matching, unknown-package fallbacks, drawable images in both appearances, and the actual supplied light/dark variants. Deep Research supplies identical artwork for both appearances; GitHub and Visualize supply different variants.

### Native glass verification

The implementation follows [Apple's AppKit adoption guidance](https://developer.apple.com/videos/play/wwdc2025/310/) and [the latest macOS design update](https://developer.apple.com/videos/play/wwdc2026/289/). Native split-view inspection confirmed an actual `NSGlassEffectView`, in regular style with no tint, owning the sidebar content. The default full-window backing was replaced with a clear scene and a nonopaque window; a behind-window material remains beneath the system glass. Temporary diagnostic flags, view logging, and the test backdrop window were removed from the final source.

Offscreen bitmap caching does not reproduce the window compositor's glass effects. Live captures also did not provide decisive proof of background-color refraction. The verified claim is the native glass implementation and removal of the masking layers, not a measured optical transparency result. System Reduce Transparency and Increase Contrast were both off during inspection; no accessibility settings were changed.

The full suite passed **479 tests** (391 Core, 42 MCP, 46 App); the local packaging script built and signed the app successfully. The latest test log is `.build/glass-home-tests.log`, and the packaging log is `.build/glass-home-package.log`. `git diff --check` passed.

Live checks during this revision covered Home, the shared Library selectors, sidebar hide/show, and the command palette with the sidebar hidden. The final packaged Home was visually inspected in light appearance. Its screenshot and accessibility tree confirmed shortened recommendation descriptions, larger type, destination actions, and ten distinct installed-tool icons. UI automation then disconnected during the icon click-through check; the app process remained running. Final Home-to-plugin/skill clicks, Discover interaction, and the final appearance toggle therefore remain unverified live. These limits are separate from the passing source/render tests.

Installation, cloud account access, sync application, and publishing are outside these checks. Changes remain uncommitted.

# macOS performance review — September 8, 2026

The reported delays have several concrete causes: repeated inventory derivation during SwiftUI rendering, synchronous filesystem work on the main actor, repeated compilation of validation expressions, and local packaging that defaulted to an unoptimized Debug binary.

## Evidence and method

- Inspected the running packaged app with 176 skills and 53 plugins, including Library navigation. A native process sample confirmed repeated marketplace projections and update evaluation in plugin rendering. Accessibility hierarchy inspection consumed a large part of that sample; automation wall time is **not** a trustworthy measurement of click latency.
- Preserved the original package sources before changing them. The before/after benchmark runs the same isolated fixture and compiler configuration: 500 skills, 100 plugins, 100 MCP servers, three observations, 25 collections, and 500 tag assignments. No real client configuration is changed and no client command is allowed.
- Environment: Apple Silicon, macOS 27.0 (26A5425a), Apple Swift 6.4 (swiftlang-6.4.0.20.104).
- Each benchmark records one first sample and five warm samples. The table below uses warm medians. Synchronous mounting includes constructing the hosting view, attaching it to a window, and requested layout. It is useful for comparing work, but is not a production frame-rate or end-to-end input-latency measurement.
- Update/settling measurements include a deliberate 60 ms run-loop window. They must not be presented as pure rendering time. The metadata change is different on every iteration; it exercises actual invalidation.
- Apple recommends reducing view-body work and unnecessary updates, and inspecting main-thread activity for hangs. See [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance) and [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/).

## Measurements

Debug before/after, warm medians on the same machine and workload:

| Work | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Skills synchronous mount | 2,288.8 ms | 124.4 ms | 94.6% |
| Skills metadata update and 60 ms settling window | 2,229.1 ms | 83.9 ms | 96.2% |
| Skills layout and bitmap drawing | 186.6 ms | 162.8 ms | 12.7% |
| Plugins synchronous mount | 305.5 ms | 277.3 ms | 9.2% |
| MCP servers synchronous mount | 446.5 ms | 377.5 ms | 15.4% |
| Snapshot validation | 386.4 ms | 40.3 ms | 89.6% |
| Snapshot JSON encoding | 18.4 ms | 16.4 ms | 10.8% |
| SQLite save, including entity encoding | 75.1 ms | 46.3 ms | 38.4% |
| Model load, including validation | 387.9 ms | 69.8 ms | 82.0% |

The clearest change is Skills' synchronous setup: **18.4 times faster**. That improvement is from code changes in the same Debug configuration. It does not attribute compiler optimization to the refactor. Skills' first sample also improved from 2,722.2 ms to 208.7 ms. Native table mount timings are noisier; do not extrapolate the smaller plugin/MCP differences into a frame-rate claim.

The primary fixture has no marketplace catalog entries. A separate fixture with 100 plugins and 500 catalog packages exercises catalog matching: synchronous Plugins mount improved from **360.7 to 274.0 ms** (24.0%); update plus the 60 ms settling window improved from **88.9 to 64.3 ms**; layout/bitmap drawing changed from **46.9 to 44.4 ms**. Release packaging is verified separately from these timings.

## Changes

| Area | Cause | Change |
| --- | --- | --- |
| Skills | Each row repeatedly decoded ownership preferences, sorted observations, searched plugin arrays, and derived provenance. Filtering and grouping were repeated within one body. | Build one indexed presentation at the inventory boundary. Reuse metadata, provenance, classifications, tags, collections, and filter choices during search/selection/scrolling. Resolve the filtered rows once per body. |
| Shared client filtering | `visibleSkills`, plugins, servers, catalogs, accounts, and other projections reconstructed arrays on every read, often from inside each row. | Cache projections until their underlying inventory or enabled-client selection changes. Retain observable source reads even on cache hits so views continue updating correctly. |
| Plugins | Each update cell repeatedly projected and scanned the marketplace catalog. | Build the update lookup when inventory/catalog inputs change, then use constant-time row lookups. |
| Connections | Switching screens synchronously enumerated plugin cache directories and parsed manifests, including when the MCP tab was displayed. | Share a background connector inventory loader between screens and reuse results until relevant input or scan state changes. |
| Skill inspector | Rendering an app toggle read and parsed native configuration files again. | Resolve native availability in the background, once per settings file; rendering reads cached values. Unrelated metadata edits preserve verified toggle state. Refresh on setup checks, native changes, and application activation. Guard against older asynchronous results overwriting newer state. Onboarding preview and final validation read fresh native state independently of the rendering cache. |
| Setup and marketplace checks | Inventory compilation and local marketplace inspection performed filesystem work on the main actor. | Move those inspections to background tasks. |
| Metadata saves | Validation rebuilt the same credential-detection regular expressions many times. Applying a saved snapshot reassigned unrelated observed arrays. | Compile validation expressions once; only assign changed persisted values. Preserve validation, atomic transactions, native write checks, and durable-save semantics. |
| Home/sidebar | Update and attention sections repeated projections and update evaluation within a render. | Reuse local results and hoist source/catalog snapshots out of per-plugin loops. |
| Icons | Repeated compiled-asset lookup; fallback SVG images reopened per render. | Cache catalog detection and decoded fallback images by appearance. |
| Packaging | Local app packaging defaulted to Debug, unlike CI. | Default packaged apps to Release; retain an explicit Debug override for development. |

## Review coverage and remaining work

Reviewed the application shell/sidebar, Home, Skills and its inspector, Plugins, Connections/MCP, Discover, onboarding, Projects, collections/configurations, activity/accounts, model observation and persistence, scanning, native availability, asset loading, and packaging.

- Native tables/lists and Discover's lazy grid already avoid eagerly rendering every row. Onboarding already uses an immutable inventory and lazy lists. These behaviors should be retained.
- Project discovery, install drift inspection, and operation execution already have background/actor boundaries. Replacing them would add risk without addressing the measured hotspots.
- Main content rendering uses native controls and materials; this pass retains the requested sidebar glass and visual design. No evidence justifies removing native materials to mask CPU work elsewhere.
- Durable metadata saves still validate and write synchronously. With validation optimized, measure the remaining cost before changing the API to an asynchronous serialized writer. A future writer must handle save ordering, conflicts, failed writes, and rollback explicitly.
- Installing, updating, importing, and creating packages can involve longer file/network work. Several plan-preparation APIs remain synchronous. A future pass should instrument these less frequent paths with large real packages and expose cancellable preparation progress where needed.
- Opening an inspector changes the split-view layout and can recreate its list subtree. Keep the current full-width list behavior, but measure inspector-open cost separately before considering a persistent split container.
- Catalog checks can still take time waiting for native CLIs or remote providers. Navigation remains available; mutation controls stay locked during operations that depend on a consistent snapshot. Faster rendering is not a claim that remote operations finish instantly.
- The benchmark is opt-in, not a machine-dependent timing assertion in ordinary CI. Use Instruments' SwiftUI and Hangs tracks on Release builds for sustained scroll/frame analysis and on substantially larger inventories. The current results do not establish a universal 60/120 fps guarantee.

## Validation

- Final regression run: **580 executed tests passed**, zero failures. The runner discovered 583 tests; one authenticated live Codex test and the two opt-in benchmarks were skipped in that ordinary run.
- Both opt-in benchmark workloads passed separately before and after the changes.
- Regression coverage includes observable cache hits, nested inventory edits, enabled-client filtering, native settings changes, shared-plugin toggles, stale asynchronous reads, unchanged-value observation behavior, connector cache invalidation, and onboarding rejecting a stale review after an external native preference change.
- `git diff --check` and packaging script syntax checks passed.
- Release compilation and packaging completed successfully. Strict, deep code-signature verification passed; the packaged executable's UUID matches the Release output (`EF81FFA4-2475-30AF-9371-F253358FE57C`). The exact worktree bundle was relaunched and its process path verified.
- Live Release inspection confirmed Home and navigation into Library → Skills with the real 176-skill inventory. Further selection/filter/scroll checks were blocked when the computer-use bridge returned `Sky Computer Use native pipe closed before response`, including after reconnecting and resetting its session. The app process remained running. These remaining interactive checks and sustained scrolling/frame-rate verification are **not** reported as passed; automated render, filtering, selection-state, and cache regression coverage passed as described above.

## Reproduction

From `apps/agent-tooling-macos`:

```sh
swift test --disable-sandbox --scratch-path .build/native
AGENT_TOOLING_BENCHMARK=1 AGENT_TOOLING_BENCHMARK_LABEL=after-debug swift test --disable-sandbox --scratch-path .build/native --filter WorkspacePerformanceTests
./scripts/package-app.sh
```

For Debug packaging, use `AGENT_TOOLING_CONFIGURATION=debug ./scripts/package-app.sh`. Run benchmarks without concurrent builds or other test suites, on the same machine and compiler configuration.

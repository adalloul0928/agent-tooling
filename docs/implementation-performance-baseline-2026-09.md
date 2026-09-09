# Implementation performance baseline

Measured September 8, 2026 from the preserved pre-goal working tree: HEAD
`fe36b65735444ab29b783ba2c1892fbb911b87f8` plus the recorded uncommitted changes.
The package was reconstructed in an isolated temporary directory. Neither live
client commands nor installations were used. One Release build/benchmark ran at
a time; implementation workers were not compiling.

Host: MacBookPro18,2, 10 physical/logical cores, 64 GiB RAM, macOS 27.0
build 26A5425a, Swift 6.4. This is one development-machine baseline, not a
controlled hardware comparison or a p95 interaction measurement.

## Workloads and method

`Tests/AgentToolingAppTests/WorkspacePerformanceTests.swift` uses an isolated
SQLite store and preferences, three client observations, 100 plugins, 100 MCP
servers, 25 collections, and either 500 or 5,000 skills. No-op command runners
fail a test if anything tries to launch a client command. Views use a dark
1180 × 850 `NSHostingView`. Each measurement reports a first sample followed by
the median and maximum of five warm samples.

Mount includes synchronous view construction and initial layout. Layout/draw
includes an offscreen bitmap capture, which has costs unlike normal compositor
presentation. Update changes one item's description. The separate settle
measurements include an intentional 60 ms run-loop window; they are **not**
response latency and are excluded from the table below.

Commands, from the isolated macOS package:

```sh
AGENT_TOOLING_BENCHMARK=1 AGENT_TOOLING_CATALOG_BENCHMARK=1 AGENT_TOOLING_BENCHMARK_LABEL=goal-baseline-release swift test --disable-sandbox -c release -j 4 --filter WorkspacePerformanceTests
AGENT_TOOLING_BENCHMARK=1 AGENT_TOOLING_BENCHMARK_SKILLS=5000 AGENT_TOOLING_BENCHMARK_LABEL=goal-baseline-release-5000 swift test --disable-sandbox -c release -j 4 --filter WorkspacePerformanceTests.representativeInventory
```

The only fixture change for the second run was the bounded skill-count option,
including proportional plugin/collection membership. Product sources remained
the pre-goal snapshot. Both commands exited 0: two tests in the first run, one
test in the second. Raw logs remain with the private baseline capture.

## Results

Warm median milliseconds; values are rounded to one decimal.

| Measurement | 500 skills | 5,000 skills |
| --- | ---: | ---: |
| Snapshot validation | 21.9 | 573.9 |
| Snapshot encoding | 17.8 | 509.8 |
| Snapshot SQLite save | 47.7 | 982.2 |
| AppModel load | 46.4 | 1,002.9 |
| Skills mount | 151.6 | 374.0 |
| Skills layout/draw | 172.9 | 314.5 |
| Skills updated layout/draw | 168.4 | 508.6 |
| Plugins mount | 225.9 | 376.3 |
| Plugins layout/draw | 44.5 | 67.2 |
| Connections mount | 384.5 | 1,149.9 |
| Connections layout/draw | 52.0 | 95.3 |

The separate 100-plugin/500-catalog-package fixture measured 249.9 ms mount,
43.3 ms layout/draw, and 43.4 ms updated layout/draw. It passed the native table
row-count assertion.

The larger run had substantial variation: Connections layout/draw warm maximum
782.3 ms versus 95.3 ms median; Skills updated layout/draw warm maximum 786.5 ms
versus 508.6 ms median. Preserve raw samples and remeasure on the same machine
after performance changes. Do not attribute every millisecond to application
code without profiling.

## Implications and remaining gates

Large-inventory persistence/load and Skills updates deserve profiling first.
The new application service must keep encoding, filesystem work, and database
writes outside SwiftUI render paths and avoid whole-workspace reconstruction
for a single-item edit. Indexed presentation models should invalidate only
the affected inventory. These measurements support that investigation; they
do not yet prove a particular algorithm is responsible.

F0 remains open for packaged-app input-to-presentation measurements of search,
filters, project switching, refresh, and scrolling. Use Instruments/signposts
to separate main-thread work from compositor costs and record the same
fixture size and host. A passing benchmark suite only confirms that the
measurement completed and its fixture assertions held; no speed threshold
was asserted. The V1 responsiveness gate still requires rendered app use and
an after-change comparison.

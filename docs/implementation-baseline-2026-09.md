# F0 implementation baseline (September 2026)

This is a read-only inventory for the first implementation milestone. It maps
the current Swift package and tests to the F0/V1 gates in the implementation
and delivery plans. No tests were run for this inventory; “covered” means a
test or implementation entry point exists, not that the gate has passed.

## Current entry points

`apps/agent-tooling-macos/Package.swift` defines one shared `AgentToolingCore`
library and three executable products: the SwiftUI app, `agent-tooling` CLI,
and `agent-tooling-mcp`. This is the intended all-Swift boundary. `AppModel.swift`
is currently `@MainActor @Observable`; `WorkspaceStore.swift` is the local
SQLite authority; `WorkspaceLibrary.swift` stages complete package trees; and
`OperationEngine.swift` executes reviewed plans in an actor.

Discovery and projection are centered in `AppModel.swift` and
`InventoryCompiler.swift`. Onboarding and ownership decisions are in
`AppModel+Onboarding.swift`; plugin/package discovery is in `ProjectDiscovery.swift`,
`AgentPluginModels.swift`, and `AgentPluginMCPModels.swift`. Assignment and
drift foundations are `Reconciliation.swift`, `OperationModels.swift`,
`StackedPlanBuilder.swift`, and the profile resolver in `AppModel.swift`.

## F0 coverage map

| Gate | Existing evidence | Status / smallest missing fixture |
| --- | --- | --- |
| Central personal content | `WorkspaceLibrary.swift` stages complete skill trees; `SkillAuthoringOriginTests.swift`, `SkillAdoptionTests.swift`, `InstallSafetyTests.swift` cover authoring/adoption and path safety. | Partial. Add one central personal package with `SKILL.md`, executable script, reference, and asset; assert the tree fingerprint includes all files and the library remains the sole editable source. |
| Central upstream content | `SkillRepositoryModels.swift`, `SkillRepositoryService.swift`, `AppModel+SkillRepositories.swift`; `SkillRepositoryTests.swift`, `DiscoveredSkillRepositoryInstallTests.swift`, `UpdateAvailabilityTests.swift`. | Partial. Existing flow updates installed copies from an isolated checkout. Add a central-materialization fixture proving publisher/ref/approved revision remain attached while the complete tree is staged into the central library. |
| Native plugin intactness | `AgentPluginModels.swift`, `PluginUpdateTests.swift`, `ProjectDiscovery.swift`, `AppModel+PluginUpdates.swift`; onboarding preserves plugin IDs and child observations. | Partial. Add one plugin fixture with parent manifest, two child skills, and an auxiliary resource; assert selection/install/update is parent-scoped and no child becomes a standalone central package. |
| Unknown/tracking-only content | `AppModel+Onboarding.swift` has preview choices and unresolved warnings; `OnboardingTests.swift`, `PersistedObservationTests.swift`, `VisibleInventoryTests.swift`. | Partial. Add an unrecognized installed skill with no binding and assert onboarding can track it without relocating, enabling, or assigning it. |
| Legacy profile nil/empty/enabled | Profile resolution and migration behavior are in `AppModel.swift` (resolver around the profile chain) and onboarding persistence in `AppModel+Onboarding.swift`; `AppModelTests.swift`, `OnboardingTests.swift`, `CollectionsTests.swift`. | Partial. Add a table fixture for `targetBindings == nil`, `[]`, and nonempty replacement, plus enabled `true`, `false`, and `nil`; compare old and proposed effective assignments and preserve each distinction. |
| Source bindings and updates | `SkillRepositoryBinding` in `SkillRepositoryModels.swift`; isolated Git fetch/validation in `SkillRepositoryService.swift`; update orchestration in `AppModel+SkillRepositories.swift`; tests listed above. | Partial. Add changed-installation and modified-destination cases: preflight must reject stale baselines, stage must be complete, and a partial receipt must leave the binding revision untrusted. |
| Plugin inheritance/assignment | Parent/child data in `AgentPluginModels.swift`; profile union and collection expansion in `AppModel.swift`; `ReconciliationPlannerTests.swift`, `StackedPlanBuilderTests.swift`, `PluginUpdateTests.swift`. | Partial. Add one profile with inherited plugin, inherited collection, and explicit child reference; assert one parent operation, deterministic reasons, and no duplicate child assignment. |
| External modifications | Fingerprints and ownership ledger in `ManagedInstallLedger.swift`, `DirectoryFingerprint.swift`, `OperationPlanSafetyReview.swift`; `LinkedInstallSafetyTests.swift`, `InstallSafetyTests.swift`, `PersistedObservationTests.swift`. | Covered for safety primitives; missing end-to-end fixture. Add an externally edited installed copy between plan and apply and assert the plan is rejected or routed to review without clobbering it. |
| Assignments and destinations | `ComponentBinding`/`Reconciliation.swift`, `OperationModels.swift`, `AppModel+Projects.swift`, `AppModel+Onboarding.swift`; `ReconciliationPlannerTests.swift`, `ProjectsAppModelTests.swift`, `ClientSelectionTests.swift`. | Partial. Add one batch containing central personal, central upstream, whole plugin, project target, and advanced linked destination; assert one physical destination gets one operation and per-target outcomes remain distinct. |
| Performance/readiness | Cached inventory in `AppModel.swift`, `InventoryCompiler.swift`, `SkillAvailabilityCacheTests.swift`, `VisibleInventoryTests.swift`; `WorkspacePerformanceTests.swift`, `WorkspaceRenderTests.swift`, `SkillsLayoutRenderTests.swift`. | Measurement gate missing. Record Release measurements with a fixed fixture size for initial load, search/filter, project switch, and source refresh; do not treat unit/render tests as latency evidence. |

## D1, D2, and AP1 starter fixtures

The smallest useful D1 fixture is a deterministic workspace document containing
one central personal package, one source-linked upstream package, one native
plugin parent with children, one unknown observed item, one project assignment,
one preset contribution, and device-only paths excluded from encoded output.
Round-trip and rename checks should preserve IDs and references.

D2 needs a legacy snapshot with the nil/empty/nonempty target-binding cases,
legacy enabled states, inherited profile/collection references, and a native
plugin observation. Migration should produce a preview/receipt, leave native
files untouched, and reject an older writer attempting to write the new format.

AP1 needs table-driven manifest inputs for required root fields, wrong field
types, forbidden nested author fields, unknown root fields, non-object
extensions, opaque unimplemented namespaces and absent-versus-null values.
Expected results must distinguish fatal diagnostics from reported/ignored
fields. Complete trees, malformed MCP declarations and resource/path isolation
belong in AP2/AP4 fixtures rather than the manifest decoder alone.

## Missing-contract risks

The largest unresolved F0 risk is that current source-update orchestration and
snapshot commits live on `AppModel` while CLI/MCP only share the queue/read
paths. D3 must establish a Swift Core application service and one cross-process
mutation owner before S3 or migration work writes central content. Existing
actors protect only one process; the current transactional protection is
explicitly strongest for the pending request queue in `WorkspaceStore.swift`.

The second risk is conflating an attached authoring repository with a linked
destination. The baseline fixtures must represent both roles separately and
include tracking-only discovery. A clean local test result will not establish
client installation, hosted sync, or two-Mac convergence.

# Burrow Remaining Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close Burrow's live-mutation hole, replace leftover demo chrome with live or empty data, persist demo receipts, and add a fixture-only executor — without shipping privileged deletion or inventing Mole cleanup paths.

**Architecture:** Status and Analyze stay live engine reads. Clean, Optimize, and Apps stay dry-run preview plus a labeled in-memory demo. Production privileged transport stays disabled. Mole 1.53 has no structured plan protocol; Burrow must not probe invented flags or invent path-level deletion sets from category previews.

**Tech Stack:** Swift 6, SwiftUI, macOS 14+, Swift Testing, existing Burrow SPM package at `apps/burrow`.

## Global Constraints

- Never launch `mo clean`, `mo optimize`, or `mo uninstall` without `--dry-run` / `--list`.
- Never invent cleanup paths; GUI must not maintain a second safe-to-delete list.
- Production default transport remains `DisabledPrivilegedOperationTransport`.
- Demo execution uses `InMemoryPrivilegedOperationTransport` and must stay labeled "Demo only".
- Do not add SMJobBless/XPC helper installation (requires an Xcode project and Developer ID; out of this plan).
- Do not change the pinned Mole 1.53 engine or probe it with unknown flags.
- Do not implement Phase 6 extras (Updates, Startup, Battery Care, Sparkle, Intel, notarization).
- Follow existing Swift patterns; smallest diff; no new dependencies.
- Tests: `cd apps/burrow && swift test`.
- Honey: YAGNI, stdlib/native first; never cut validation, error handling, or auth.

## Out of scope (explicit)

- Signed privileged helper, Authorization Services production adapters, notarization.
- Upstream Mole `--plan-json` / progress NDJSON (Phase 3 remains blocked on Mole).
- Apps related-file enumeration.
- Rewriting the app as an Xcode multi-package project.

## PR Plan

### PR 1: Close live Mole mutation; wire demo execution UI

**Description:** Remove the phrase-gated `LiveMaintenanceSheet` path that runs real `mo clean` / `mo optimize` / `mo uninstall`. Wire Clean, Optimize, and Apps "run" buttons to the existing labeled `ExecutionFlowSheet` demo. Delete engine execute methods so no UI or protocol path can mutate via Mole. Optimize idle list must not show `DemoData.optimizeTasks` as if they were a plan.

**Files/components affected:** `apps/burrow/Sources/Burrow/CleanView.swift`, `apps/burrow/Sources/Burrow/OptimizeView.swift`, `apps/burrow/Sources/Burrow/AppsView.swift`, `apps/burrow/Sources/Burrow/AppState.swift`, `apps/burrow/Sources/Burrow/EngineClient.swift`, `apps/burrow/Sources/Burrow/LiveMaintenanceSheet.swift`, `apps/burrow/Tests/BurrowTests/AppStateTests.swift`, `apps/burrow/Tests/BurrowTests/EngineContractTests.swift`

**Dependencies:** None

Requirements:

1. Delete `LiveMaintenanceSheet.swift`. Nothing may present it.
2. Clean "Clean now" presents `ExecutionFlowSheet(model: appState.cleanExecution, currentPreviewFingerprint: plan.metadata.fingerprint, accent:)`. Enable the button when `cleanExecution != nil` (live adapter **or** demo fallback). Both run the in-memory demo only.
3. Optimize "Optimize now" same pattern with `optimizeExecution`.
4. Apps "Uninstall" calls `prepareAppsExecution()` then presents `appsExecution` in `ExecutionFlowSheet`. Enable when selection is non-empty and `appsExecution != nil` after prepare (inventory source may be live; execution is still demo).
5. Remove `executeClean`, `executeOptimize`, `executeUninstall` from `EngineClientProtocol`, `MoleEngineClient`, and `AppState`.
6. Optimize `displayTasks`: if `optimizePlan` is nil, show an empty/awaiting state, not `DemoData.optimizeTasks`.
7. Tests: protocol/client have no execute methods; AppState has no execute wrappers; a preview still builds `cleanExecution` via `FixtureExecutionPresentationFactory`.
8. `swift test` passes.

### PR 2: Replace fake Status and menu-bar metrics

**Description:** Status CPU badge currently hardcodes `44°C`. Menu bar hardcodes `↓ 8 · ↑ 3 KB/s`. Use `StatusSnapshot.thermal` and `StatusSnapshot.network` already decoded from `mo status --json`. Do not touch Clean/Optimize/Apps.

**Files/components affected:** `apps/burrow/Sources/Burrow/StatusView.swift`, `apps/burrow/Sources/Burrow/MenuBarDashboard.swift`, `apps/burrow/Tests/BurrowTests/AppStateTests.swift`

**Dependencies:** None

Requirements:

1. `MetricCard` for CPU: badge is `"\(Int(snapshot.thermal.cpuTemp.rounded()))°C"` when a snapshot exists; otherwise `"LIVE"` is acceptable only when there is no thermal reading. Never hardcode 44.
2. Menu bar Network row uses the same rate formatting as `StatusView.rate` on `receiveMBs`/`transmitMBs` of the first network interface. Empty snapshot shows `—`.
3. Battery and top process already live; leave them.
4. Add or extend a test that formats network rates and thermal display from a fixture snapshot if one exists; otherwise a small pure helper is allowed (one function, no new types if StatusView.rate can be reused as `enum StatusMetricsFormatting`).
5. `swift test` passes.

### PR 3: Wire demo receipts into persistence and Clean footer

**Description:** `FileOperationReceiptStore` exists but is unwired. Persist fixture-simulation receipts after a demo run completes. Clean footer must stop showing `"8 days ago"`, `"148.2 GB"`, `"12 paths"`.

**Files/components affected:** `apps/burrow/Sources/Burrow/AppState.swift`, `apps/burrow/Sources/Burrow/CleanView.swift`, `apps/burrow/Sources/Burrow/ExecutionPresentation.swift`, `apps/burrow/Sources/Burrow/OperationReceiptStore.swift`, `apps/burrow/Tests/BurrowTests/OperationReceiptStoreTests.swift`, `apps/burrow/Tests/BurrowTests/AppStateTests.swift`

**Dependencies:** PR 1

Requirements:

1. AppState owns an `any OperationReceiptStoring` (default `FileOperationReceiptStore` in Application Support `Burrow/receipts`, injected for tests).
2. When `ExecutionPresentationModel` reaches `.receipt`, save with `provenance: .fixtureSimulation`. Do not save authenticated-helper provenance from the demo path.
3. Load receipts on `startReadOnlyServices`.
4. Clean footer: Last clean = relative time of latest stored receipt or `—`; Lifetime reclaimed = sum of completed receipt byte totals or `0 B`; Protected = omit fake `12 paths` — use `—` or drop that column. Label the footer as demo history if any receipt is fixtureSimulation.
5. Keep store validation/permissions as they are. Do not weaken provenance checks.
6. Tests: saving a demo receipt then reading footer-derived values; invalid provenance still rejected.
7. `swift test` passes.

### PR 4: Fixture-root executor (tests only)

**Description:** Add a transport that can mutate files **only** under an injected temporary root, for contract tests. Shipping app must not use it. Reject any path that escapes the root (symlinks, `..`, absolute paths outside). This is the executable kernel a future XPC helper would call; it is not that helper.

**Files/components affected:** `apps/burrow/Sources/Burrow/OperationTransports.swift`, `apps/burrow/Tests/BurrowTests/FixtureRootTransportTests.swift` (create), `apps/burrow/Tests/BurrowTests/OperationCoordinatorTests.swift`

**Dependencies:** None

Requirements:

1. New `FixtureRootOperationTransport` taking a root URL. `execute` performs only actions already in the validated `ExecutionPlan`, using descriptor-relative / no-follow semantics already described in `FilesystemActionResolving` if a resolver exists; otherwise `FileManager` with `standardizingPath` + `hasPrefix(root)` checks and `URL.resolvingSymlinksInPath` comparison so a symlink out of root fails.
2. Support the action kinds already on `ExecutionAction` that are safe in a temp tree (trash/remove file, remove empty directory). Unsupported kinds fail closed.
3. Emit the existing `ExecutionProgressEvent` sequence (`started` → per-item → terminal).
4. `AppState` / shipping `BurrowApp` must still construct `DisabledPrivilegedOperationTransport` for production and in-memory for demo. Do not wire FixtureRoot into the app.
5. Tests in a unique temp directory: allowed delete succeeds; path outside root throws; symlink-escape throws; empty dir vs non-empty matches existing contract (`directoryNotEmpty`).
6. `swift test` passes.

### PR 5: Contract docs and truthful status

**Description:** Write the missing contract docs and fix README/architecture so they match the post-PR-1–4 product. Section 17 of the architecture plan is stale.

**Files/components affected:** `apps/burrow/docs/engine-contract.md` (create), `apps/burrow/docs/safety-model.md` (create), `apps/burrow/README.md`, `docs/superpowers/plans/2026-09-03-mole-inspired-macos-app-architecture.md`, `README.md`

**Dependencies:** PR 1, PR 2, PR 3, PR 4

Requirements:

1. `engine-contract.md`: Mole 1.53 commands Burrow actually runs; dry-run write caveat for clean-list.txt; no execute verbs; structured protocol marker `burrow-plan-v1`; demo vs live source badges.
2. `safety-model.md`: preview vs demo vs disabled production transport; receipts provenance; Analyze `trashItem` is user-context and confirmed; fixture executor is tests-only; helper/XPC not installed.
3. README current behavior: delete any claim that contradicts LiveMaintenanceSheet removal; state Analyze-to-Trash exists; state Clean/Optimize/Apps run is in-memory demo; receipts persist locally with demo provenance.
4. Architecture plan: update Status line; replace section 17 with the next real task (Xcode helper + Developer ID + Mole plan JSON); mark Phase 6 still deferred.
5. Workbench README: Burrow remains prototype / safe demo mode.
6. No source behavior changes in this PR.

---

## Delivery sequence vs this plan

| Architecture phase | This plan |
|---|---|
| 0–2 foundation, shell, Status/Analyze | Already present in the prototype |
| 3 structured Mole protocol | Documented gap only |
| 4 safe execution | Demo UI + fail-closed production + test fixture executor |
| 5 hardening/release | CI already exists; notarization not in this plan |
| 6 differentiated utilities | Still deferred |

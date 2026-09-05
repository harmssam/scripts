# Mole-Inspired macOS App Architecture

**Status:** Phase 4 safety foundation implemented; privileged/destructive execution remains disabled  
**Platform:** macOS 14+, Apple Silicon first  
**Working location:** `apps/burrow/`  
**Working title:** Burrow (rename before release if brand review requires it)

## 1. Product intent

Build a polished, native macOS maintenance app on top of the open-source
[tw93/Mole](https://github.com/tw93/Mole) engine. The experience should cover the same five primary jobs shown by Mole for Mac:

1. **Clean** — scan, review, protect, and remove safe/rebuildable files.
2. **Apps** — inspect installed applications and remove apps with related files.
3. **Optimize** — preview and run bounded macOS maintenance tasks.
4. **Analyze** — explore disk usage through a navigable treemap.
5. **Status** — monitor system health and processes in real time.

The app is inspired by Mole's product principles and spatial organization, not a pixel-for-pixel or branded copy. It must use an original product name, icon, copy, and artwork.

## 2. Licensing and brand boundary

This is an architecture constraint, not release cleanup:

- The current upstream Mole CLI is **GPL-3.0**, not MIT.
- Upstream's `TRADEMARK.md` reserves the **Mole** name/logo and describes Mole for Mac as a separate proprietary product with reserved assets.
- Do not ship the Mole name, mole logo, screenshots, planet renders, marketing copy, or imply affiliation.
- Create original celestial/organic artwork and original UI copy.
- Simplest compliant distribution: license the complete app under GPL-3.0, ship required notices, publish corresponding source, and document the exact upstream revision.
- If a different app license is wanted, keep the CLI as a separately installed executable and get legal review before distribution. Separate-process invocation reduces coupling but does not remove every distribution obligation if the CLI is bundled.

## 3. Scope

### First public release

- Native SwiftUI application with five primary tabs.
- Bundled, pinned Mole CLI engine and Go helper binaries for `arm64`.
- Full Disk Access onboarding and clear degraded-mode behavior.
- Dry-run-first Clean, Optimize, and Uninstall flows.
- Reviewable selection and confirmation before every destructive action.
- Trash-first removal wherever upstream supports recoverability.
- Live Status using Mole's JSON/NDJSON output.
- Disk Analyze using Mole's JSON output with a native treemap.
- Menu bar health summary backed by the same metrics session.
- Local preferences and local operation history; no account and no telemetry by default.

### Explicitly deferred

- Intel distribution.
- App update aggregation (Sparkle/App Store/Homebrew), login-item management, Battery Care, fan control, privacy camera/microphone alerts, Keep Screen On, and Clean Screen.
- Automatic scheduled cleanup.
- A privileged always-running daemon.
- Any cleanup rule invented by the GUI rather than supplied by the engine.

These can follow after the five core vertical slices are safe and stable. They are paid-app features shown on the site, not capabilities already supplied by the open-source CLI.

## 4. Experience architecture

The window uses a single, centered capsule navigation control rather than a conventional macOS sidebar. Each feature owns a restrained color atmosphere and one primary visual metaphor.

| Area | Primary composition | Feature accent | Main action |
|---|---|---|---|
| Clean | Large original orb, reclaimable-space value, review drawer | Deep blue/cyan | Scan → Review → Clean |
| Apps | Dense expandable app rows with icon, size, activity, leftovers | Rust/coral | Review → Remove |
| Optimize | Orb/progress focal point and live task ledger | Olive/gold | Preview → Optimize |
| Analyze | Folder rail, breadcrumb, proportional treemap | Umber/sand | Navigate / Move to Trash |
| Status | Health-card grid and sortable process table | Moss/amber | Read-only monitoring |

Shared visual rules:

- Near-black tinted canvases rather than pure black.
- A feature-specific atmospheric gradient that changes gently when tabs change.
- Capsule navigation, 18–24 pt continuous card corners, 1 px low-contrast borders, and restrained material blur.
- SF Pro for interface copy; SF Mono for sizes, paths, metrics, and progress details.
- Off-white primary text, muted warm-gray secondary text, and semantic green/amber/red used only for status.
- Data density grows downward: expressive focal area first, review/detail surfaces second, fixed action bar last.
- Motion is calm: 180–260 ms state transitions; orb motion is slow and optional. Respect Reduce Motion and Reduce Transparency.
- Minimum hit target 32 pt on macOS; every graph and color signal has a text equivalent.

Do not make the artwork a dependency of the domain state. The UI must remain fully functional with static placeholder orbs, enabling accessibility, tests, and a reduced-motion mode.

## 5. High-level system

```text
SwiftUI App / MenuBarExtra
          │
          ▼
Feature Stores (@Observable, @MainActor)
          │
          ▼
Use Cases + Domain Models (Sendable, UI-independent)
          │
          ▼
EngineClient actor ──────── SystemMetricsSession actor
     │                              │
     ├── Mole CLI subprocess        └── status --watch (NDJSON)
     ├── JSON/NDJSON decoders
     ├── versioned text adapters (temporary)
     └── PrivilegeBroker ── signed helper/XPC for approved plans
```

The app owns presentation and orchestration. Mole owns cleanup policy, target discovery, path protection, dry-run behavior, and deletion semantics. The GUI must never maintain a second list of paths that it considers safe to delete.

## 6. Repository layout

Use an Xcode app project with local Swift packages. An Xcode project is preferable here because the product needs signing, entitlements, a helper target, menu-bar behavior, resources, and release archives.

```text
apps/<product-name>/
├── <Product>.xcodeproj
├── App/
│   ├── ProductApp.swift
│   ├── AppDelegate.swift
│   ├── AppRouter.swift
│   ├── AppDependencies.swift
│   └── Resources/
├── Packages/
│   ├── DesignSystem/
│   ├── Domain/
│   ├── EngineClient/
│   ├── FeatureClean/
│   ├── FeatureApps/
│   ├── FeatureOptimize/
│   ├── FeatureAnalyze/
│   ├── FeatureStatus/
│   ├── FeatureMenuBar/
│   └── Support/
├── Helper/
│   ├── PrivilegedHelperProtocol.swift
│   └── PrivilegedHelperService.swift
├── Vendor/
│   ├── Mole/                 # pinned upstream source/revision
│   ├── bin/                  # reproducibly built release artifacts
│   └── THIRD_PARTY_NOTICES.md
├── Tests/
│   ├── Fixtures/
│   ├── ContractTests/
│   ├── FeatureTests/
│   └── SnapshotTests/
├── scripts/
│   ├── sync-mole.sh
│   ├── build-engine.sh
│   └── verify-bundle.sh
└── docs/
    ├── architecture.md
    ├── engine-contract.md
    ├── safety-model.md
    └── design-system.md
```

## 7. State and dependency model

Create one composition root (`AppDependencies`) and small feature stores. Avoid a single global app model and avoid directly constructing services inside views.

```swift
struct AppDependencies: Sendable {
    let engine: any EngineClientProtocol
    let metrics: any MetricsSessionProtocol
    let privileges: any PrivilegeBrokerProtocol
    let workspace: any WorkspaceProtocol
    let history: any OperationHistoryProtocol
    let settings: any SettingsStoreProtocol
}
```

Each feature store is `@Observable @MainActor`; subprocesses, filesystem enumeration, decoding, caching, and metric collection live in actors. Domain types are immutable and `Sendable`.

Every operation uses an explicit state machine rather than independent booleans:

```text
idle
 └─ scanning(progress)
     ├─ review(plan)
     │   ├─ authorizing(plan)
     │   └─ executing(progress)
     │       ├─ completed(receipt)
     │       ├─ cancelled(partialReceipt?)
     │       └─ failed(error, partialReceipt?)
     └─ failed(error)
```

The plan reviewed by the user receives an ID/hash. The executor must run that same immutable plan or require a new preview. This prevents a stale UI selection from turning into a different deletion set.

## 8. Engine boundary

### Command runner

`EngineClient` launches executables directly with `Process.executableURL` and an argument array. Never compose user-controlled paths into `/bin/bash -c` strings.

Responsibilities:

- Resolve only the signed/bundled engine path or an explicitly configured development path.
- Scrub and explicitly build the child environment (`PATH`, locale, dry-run/test flags).
- Stream stdout and stderr concurrently without pipe deadlocks.
- Decode UTF-8 incrementally, support cancellation, and terminate the full process group.
- Apply per-command timeouts without treating a timeout as successful cancellation.
- Strip ANSI only in the compatibility parser.
- Redact home-directory paths and usernames from diagnostics exported by the user.
- Return typed errors: unavailable, incompatible version, permission denied, timed out, cancelled, malformed response, partial failure, and engine failure.

### Structured contract

Use structured output wherever upstream already provides it:

| Capability | Contract |
|---|---|
| Status snapshot | `mo status --json` |
| Status stream | `mo status --watch --interval 2s` NDJSON |
| Analyze | `mo analyze --json <path>` |
| Installed app inventory | upstream uninstall list JSON mode |
| Operation history | `mo history --json` |

Clean, Optimize, Purge, and Installer are still primarily interactive text flows. Do not spread regex parsing through feature stores. Put temporary parsing behind versioned adapters such as `CleanOutputAdapter_v1_48`, with golden fixtures and strict failure on unknown output.

Before the first destructive release, add a small maintained engine patch that exposes a stable GUI protocol:

```text
mo clean --plan-json
mo clean --execute-plan <plan-file> --events-jsonl
mo optimize --plan-json
mo optimize --execute-plan <plan-file> --events-jsonl
mo uninstall --plan-json <bundle-id...>
mo uninstall --execute-plan <plan-file> --events-jsonl
```

Suggested envelope:

```json
{"schema":1,"type":"progress","operation_id":"…","step":4,"total":12,"message":"Scanning browser caches"}
```

The engine version and protocol schema are checked at launch. Unsupported versions show a clear update/recovery screen instead of attempting best-effort destructive parsing.

## 9. Privilege and safety model

- Full Disk Access and administrator authorization are separate states and must be explained separately.
- The app scans first in the current user context and shows inaccessible categories as unavailable—not as zero bytes.
- Only an immutable, reviewed operation plan can cross into the privileged boundary.
- The helper accepts structured operations from a small allowlist; it does not accept arbitrary shell strings or arbitrary executables.
- Validate canonical paths, ownership, symlink behavior, protected roots, and plan hash again inside the privileged process immediately before action.
- Batch related privileged work under one user authorization when possible.
- Default to dry run and selection review. High-risk or ambiguous categories start unselected.
- Never silently convert a Trash operation into permanent deletion.
- Persist a local receipt containing timestamps, engine version, action types, counts, byte totals, and outcomes. Avoid logging file contents or sensitive path fragments.
- Cancellation means “stop starting new work”; the receipt must state what already completed.

The first milestone can ship read-only Status and Analyze without a helper. Do not ship real Clean/Optimize/Uninstall until the structured plan and privilege boundaries are tested.

### Phase 3 implementation status (2026-09-03)

- Added immutable, `Codable`, `Sendable` schema-one plan contracts for Clean, Optimize, and Apps/Uninstall.
- Each plan carries the producing engine version, live-vs-demo source, warnings, and a deterministic SHA-256 fingerprint over canonical plan evidence. App selections derive a new fingerprint.
- Added a strict `MolePreviewAdapter_v1_53`. Clean invokes only `mo clean --dry-run`; Optimize invokes only `mo optimize --dry-run`; Apps invokes only `mo uninstall --list`, whose piped output is JSON in Mole 1.53.
- Mole 1.53 Clean dry-run refreshes `~/.config/mole/clean-list.txt`; the UI therefore says “no cleanup performed” instead of claiming the preview subprocess is completely write-free.
- The text adapters require explicit dry-run and no-change completion markers and fail closed on unknown output. Golden fixtures pin accepted 1.53 shapes.
- Clean, Optimize, and Apps display real preview evidence when available and visibly label demo fallback. There is no destructive engine API, privileged helper, or execution path in this phase.
- Uninstall is intentionally inventory-only: related-file discovery requires the future structured upstream `--plan-json` contract before it can be represented as executable evidence.

### Phase 4 safety-foundation status (2026-09-04)

- Added action-specific, path-level schema-one execution contracts with stable file identities, canonical cross-language fingerprints, empty-only directory removal, replacement source/postcondition hashes, narrow per-action roots, overlap rejection, and strict started-to-terminal progress validation.
- Added plan-derived confirmation, cancellation, timeout, progress, bounded privacy-safe receipts, and review-to-receipt presentation. The only runnable flow is prominently labeled as an in-memory demo scenario; the production transport still fails closed.
- Added a helper authorization boundary with injected audit-token/client authentication and user-authorization verification, helper-issued short-lived single-use tickets, trusted UID/home binding, bounded replay state, and opaque descriptor-style action handles. It is not connected to XPC or a filesystem executor.
- Added schema-versioned local receipt storage with mandatory demo-versus-authenticated-helper provenance, semantic invariant checks, private permissions, no-follow containment checks, and bounded privacy-safe corruption handling. Persistence is not yet wired to production execution.
- Hardened distribution around a pinned Mole 1.53.0 source/binary release: immutable archive verification, explicit inner-to-outer signing, atomic bundle replacement, signed native launcher, CI toolchain pinning, and release verification hooks.
- Current automated gate: 67 tests across 9 suites, repeated cleanly; release build and ad-hoc signed bundle with the pinned engine verify successfully.

Remaining Phase 4 work is intentionally blocked from production until a separately signed XPC helper and descriptor-relative executor exist, are authenticated with real macOS audit-token/Authorization Services adapters, and pass destructive tests exclusively inside disposable fixtures/VMs.

## 10. Feature modules

### Clean

- `CleanStore` requests a scan/plan, groups entries by engine category, and derives totals from the returned plan.
- The idle/scanning surface uses original orb artwork; the review surface is a native outline/list with category totals and item disclosure.
- Provide Protect/Skip controls backed by upstream whitelist behavior.
- Completion presents freed space, elapsed time, skipped items, and a receipt link.

### Apps

- One `AppsStore` owns three internal routes: Uninstall now; Updates and Startup later.
- Inventory rows are keyed by bundle URL + bundle identifier, never display name alone.
- Expanded rows show the exact related-file evidence supplied by the engine.
- App removal must re-check whether the app is running and whether a shared bundle identifier is still in use.

### Optimize

- Preview all proposed tasks with plain-language purpose and expected effect.
- Stream step events into a compact ledger beneath the main progress focal point.
- Render skipped and not-applicable tasks as first-class outcomes, not errors.

### Analyze

- `AnalyzeStore` owns breadcrumb history, selection, sort, scan cache, and delete-plan creation.
- Treemap layout is a pure function in `Domain`, using squarified tiling and deterministic colors derived from file category—not random colors.
- Very large result sets are summarized by the engine; SwiftUI receives only display nodes.
- Context actions: Open, Reveal in Finder, Copy Path, and Move to Trash with confirmation.
- System-protected locations are visibly read-only.

### Status

- A single `SystemMetricsSession` actor owns one NDJSON subprocess and multicasts snapshots to the main window and menu-bar UI.
- Ring buffers live outside SwiftUI and retain only the samples needed for sparklines.
- The UI refreshes at a bounded cadence even if events arrive faster.
- Process rows are sortable; killing processes is out of scope for V1.
- Pause or reduce collection while the app is hidden and no menu-bar surface is active.

### Menu bar

- `MenuBarExtra` is a compact projection of `SystemMetricsSession`; it must not launch a second collector.
- V1 includes health, CPU, memory, disk, network, battery when available, and top processes.
- Opening the main app focuses Status. Quit and Settings remain native menu commands.

## 11. Design-system components

Build reusable primitives before feature screens:

- `FeatureCanvas`, `AtmosphericGradient`, `OrbStage`
- `CapsuleTabBar`, `SegmentedPill`, `PrimaryCapsuleButton`
- `MetricCard`, `MetricValue`, `Sparkline`, `StatusBadge`
- `ReviewRow`, `DisclosureFileTree`, `SelectionSummaryBar`
- `ProgressLedger`, `EmptyState`, `PermissionState`, `ErrorState`
- `Treemap`, `BreadcrumbBar`, `ProcessTable`
- Typography, spacing, radius, border, material, motion, and feature-color tokens

All components receive semantic tokens through the environment. Feature code should not contain ad hoc RGB values, corner radii, shadows, or animation durations.

## 12. Persistence

Use small, inspectable local stores:

- `UserDefaults`: selected tab, display preferences, menu-bar visibility, Reduce Motion override.
- Upstream Mole config directory: whitelists and engine-owned preferences.
- Application Support: operation receipts, cached analyze summaries, schema/version metadata.
- Keychain only if a future feature genuinely has a secret; V1 has none.

Do not persist raw live metrics or a catalog of the user's filesystem by default. Analyze caches get an expiry and are invalidated after app-initiated file operations.

## 13. Testing strategy

### Contract tests

- Pin representative JSON/NDJSON and text fixtures for every supported engine version.
- Decode unknown/additive JSON fields safely while failing on missing safety-critical fields.
- Verify malformed/truncated output, nonzero exits, cancellation, timeouts, and partial receipts.
- Run the compatibility suite whenever the pinned Mole revision changes.

### Domain and feature tests

- State-machine transition tests for every feature.
- Plan identity/hash, stale-plan refusal, default selection, and byte-total tests.
- Treemap determinism, zero-size input, huge values, deep navigation, and cache invalidation.
- Metrics fan-out, backpressure, bounded history, and collector lifecycle.

### Safety integration tests

- Use temporary fixture trees only; never point tests at a real home directory.
- Run all destructive engine tests with Mole's test/no-auth and dry-run controls.
- Cover symlink swaps, protected paths, ownership changes, disappearing files, app-running checks, shared bundle IDs, cancellation, and partial failure.
- Verify the helper rejects arbitrary commands, unknown plan schemas, changed hashes, and out-of-scope paths.

### UI and visual tests

- Snapshot the five primary screens in idle, loading, review, completion, empty, permission-denied, and failure states.
- Test light/dark contrast even if dark is the signature experience.
- Test VoiceOver labels/order, keyboard navigation, large text, Reduce Motion, Reduce Transparency, and 980×700 minimum window size.
- Add a demo/fixture mode so the complete UI can be developed without touching the real filesystem.

## 14. Release and update architecture

- Developer ID signing, hardened runtime, notarization, and stapled DMG/ZIP.
- Generate SBOM/third-party notices and record the exact Mole commit and Go toolchain.
- Reproducibly build bundled engine binaries in CI; do not download/execute an unverified engine on first launch.
- Verify code signatures and hashes for every executable inside the bundle.
- Treat app updates and engine updates as one signed release unit for V1.
- Add Sparkle only after the signed/notarized archive pipeline is stable.
- No Mac App Store target initially; sandboxing conflicts with whole-disk inspection and bundled maintenance workflows.

## 15. Delivery sequence

### Phase 0 — foundation and compliance

- Choose final product name and original icon/art direction.
- Decide GPL-compatible distribution model.
- Create Xcode project, package boundaries, CI, signing placeholders, third-party notices, and upstream pinning script.
- Capture engine fixtures and write `engine-contract.md` plus `safety-model.md`.

**Exit:** clean build/test on macOS 14+, exact upstream revision recorded, no Mole branding in app assets.

### Phase 1 — beautiful shell in demo mode

- Implement design tokens, feature canvas, capsule navigation, window chrome, shared components, original static orb placeholders, and fixture-backed stores.
- Build all five screens and menu-bar popover against deterministic demo data.

**Exit:** complete keyboard-accessible product walkthrough with no real filesystem mutations.

### Phase 2 — read-only vertical slices

- Integrate Status JSON/NDJSON and Analyze JSON.
- Add Full Disk Access detection/degraded states.
- Connect real metrics to both main window and menu bar.

**Exit:** production-quality Status and Analyze; Analyze actions remain Open/Reveal only.

### Phase 3 — structured engine protocol

- Add/version plan JSON and progress NDJSON for Clean, Optimize, and Uninstall in the vendored fork or upstream contribution.
- Implement strict decoders, compatibility matrix, golden fixtures, and plan hashing.

**Exit:** real scans/previews populate the UI; execution remains disabled.

### Phase 4 — safe execution

- Implement the signed privilege helper and XPC allowlist.
- Enable Clean, Optimize, Uninstall, Analyze-to-Trash, receipts, cancellation, and recovery.

**Exit:** every mutation is previewable, confirmed, plan-bound, logged, tested in fixtures, and revalidated at the action boundary.

### Phase 5 — hardening and release

- Performance profiling, energy testing, accessibility audit, localization groundwork, crash recovery, notarization, and clean-Mac acceptance tests.
- Test with limited permissions, no Homebrew, no network, unusual usernames/paths, low disk space, and both fresh and upgraded installs.

**Exit:** signed beta with documented limitations and recovery path.

### Phase 6 — differentiated utilities

- Evaluate Updates, Startup Items, Battery Care, privacy activity, fan controls, Keep Screen On, and Clean Screen as independent proposals.
- Each feature needs its own safety/privacy model; none should be inferred as part of the CLI wrapper.

## 16. Architecture decisions to hold

1. **Native SwiftUI/AppKit**, not a web wrapper: the app needs macOS metrics, permissions, menu-bar integration, Finder actions, signing, and a privileged boundary.
2. **CLI engine behind a protocol**, not shell output inside views: the UI stays testable and engine changes remain localized.
3. **Structured plans before mutations**: beautiful review UI is only trustworthy when it shows the exact plan that will execute.
4. **One metrics process** shared by all surfaces: avoids duplicate CPU cost and contradictory readings.
5. **Original brand/art assets**: reuse ideas and GPL code lawfully, not proprietary identity.
6. **Demo mode first**: visual polish can advance quickly without risking user data.
7. **Read-only slices before destructive slices**: validates packaging, responsiveness, and protocol handling before introducing authorization and deletion.

## 17. Immediate next implementation task

Create `apps/<product-name>/` with the Xcode shell, local packages, semantic design tokens, capsule navigation, and fixture-backed implementations of the five screens. Keep all destructive controls in demo mode until the structured engine plan protocol is complete.

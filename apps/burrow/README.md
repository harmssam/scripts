# Burrow

Working-name native macOS maintenance interface inspired by the calm, atmospheric presentation of Mole for Mac. Status and Analyze use the installed Mole CLI through a typed adapter. Clean, Apps, and Optimize expose immutable previews and a labeled in-memory execution demo. There is no Mole cleanup, optimize, or uninstall execute path (`LiveMaintenanceSheet` is gone).

## Current behavior

- Burrow discovers `mo` in the signed app bundle, `/opt/homebrew/bin`, or `/usr/local/bin`.
- Status and the menu bar refresh from `mo status --json` through one shared application state. The CPU badge uses `thermal.cpuTemp`. Network uses live rx/tx rates.
- Analyze can scan a user-selected directory with `mo analyze --json`. Move to Trash uses `FileManager.trashItem` in the user context after confirmation.
- Missing/incompatible engines fall back to clearly marked demo data.
- Full Disk Access is reported separately from engine availability.
- The process runner launches `mo` directly with argument arrays and a scrubbed environment; it never constructs shell command strings.
- Clean calls only `mo clean --dry-run`; Optimize calls only `mo optimize --dry-run`; Apps calls only `mo uninstall --list` (Mole 1.53 emits JSON when piped).
- Upstream Clean dry-run refreshes its own `~/.config/mole/clean-list.txt` preview manifest. Burrow therefore promises “no cleanup performed,” rather than claiming the preview process performs no writes at all.
- Mole 1.53 text is isolated in a strict versioned compatibility adapter. Missing dry-run/no-change markers fail closed.
- Every preview is a schema-versioned immutable value with a deterministic SHA-256 fingerprint, engine version, source, and warnings.
- UI badges distinguish live engine previews (`LIVE PREVIEW`) from demo fallback (`UNAVAILABLE`).
- Clean, Optimize, and Apps “run” opens labeled `ExecutionFlowSheet` and uses `InMemoryPrivilegedOperationTransport`. It cannot access the filesystem.
- Production default transport is `DisabledPrivilegedOperationTransport`. Helper authorization is a testable boundary only: no XPC service, helper installation, or SMJobBless.
- `FixtureRootOperationTransport` exists for tests only (`openat` / `O_NOFOLLOW` / `unlinkat` under an injected root). It is not wired into `AppState`.
- Demo receipts persist locally under Application Support `Burrow/receipts` with `fixtureSimulation` provenance. The Clean footer reads that history.
- `executionPlan` is gated on `burrow-plan-v1` in `mo --version` and is unused by the UI.
- No `executeClean` / `executeOptimize` / `executeUninstall` methods exist.
- Apps Updates and Startup are not implemented.

The compatibility adapter intentionally supports Mole 1.53.x only. A different version falls back to demo data until its output has golden fixtures and a reviewed adapter. Apps provides real inventory evidence, but related-file enumeration remains unavailable until upstream exposes a non-interactive structured uninstall plan.

See [docs/engine-contract.md](docs/engine-contract.md) and [docs/safety-model.md](docs/safety-model.md).

## Run

```bash
swift run
```

## Test and build an app bundle

```bash
swift test
./build-app.sh
open dist/Burrow.app
```

The default build has no bundled engine and can use a separately installed
Mole CLI. For a reproducible bundle containing the pinned Mole 1.53.0 engine:

```bash
./build-app.sh --with-engine
./scripts/verify-app-bundle.sh dist/Burrow.app
```

The build downloads source and helper archives but never executes downloaded
code during acquisition. Every archive is checked against repository-pinned
SHA-256 values and Mole's published checksum file. The complete corresponding
source is included in the app bundle. Existing staging directories are never
overwritten; remove one explicitly before deliberately refreshing it.
The bundled `mo` entrypoint is a minimal native launcher built from
`Sources/MoleLauncher/main.c`, allowing every executable code object to be
signed explicitly.

The default build uses an explicit ad-hoc development signature. It constructs
and verifies a sibling staging bundle before replacing the last good app. For a
Developer ID release candidate, provide the full signing identity and Team ID:

```bash
BURROW_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID1234)" \
BURROW_TEAM_ID="TEAMID1234" \
./build-app.sh --with-engine
```

Release signing is explicit from inner helper executables to the outer app and
enables the hardened runtime and secure timestamp. The build does not use
`codesign --deep`, notarize, or publish. After notarizing in a separate,
credentialed release job, require ticket and Gatekeeper validation with:

```bash
BURROW_TEAM_ID="TEAMID1234" \
BURROW_REQUIRE_RUNTIME=1 \
BURROW_REQUIRE_NOTARIZATION=1 \
./scripts/verify-app-bundle.sh dist/Burrow.app
```

Run the same test, bundle, and verification sequence as CI with:

```bash
./scripts/ci.sh
```

Dependency provenance is documented in [ThirdParty/Mole](ThirdParty/Mole) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Burrow intentionally retains
its own name and visual identity; Mole trademarks and application assets are
not included.

Requires macOS 14 or later and Swift 6.

See the [architecture plan](../../docs/superpowers/plans/2026-09-03-mole-inspired-macos-app-architecture.md) for the engine, safety, licensing, and delivery design.

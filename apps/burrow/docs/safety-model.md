# Safety model

Burrow is a prototype. Status and Analyze are live reads. Clean, Optimize, and Apps mutate nothing through Mole.

## Preview vs demo vs production transport

| Layer | What it does | Filesystem |
|---|---|---|
| Preview | `mo clean --dry-run`, `mo optimize --dry-run`, `mo uninstall --list` | Clean dry-run may refresh `~/.config/mole/clean-list.txt`. No cleanup, optimize, or uninstall. |
| Demo run | `ExecutionFlowSheet` + `InMemoryPrivilegedOperationTransport` | In-memory event replay only. Label: `DEMO SCENARIO · NO FILES WILL CHANGE`. |
| Production default | `DisabledPrivilegedOperationTransport` | Always throws `unavailableTransport`. Shipping `AppState` / `BurrowApp` use this boundary, not a live helper. |

`LiveMaintenanceSheet` is deleted. There is no `executeClean` / `executeOptimize` / `executeUninstall`.

## Receipts provenance

Demo receipts persist under Application Support `Burrow/receipts` via `FileOperationReceiptStore`.

`OperationReceiptProvenance`:

- `fixtureSimulation` — the only provenance the demo path may save
- `authenticatedHelper` — reserved; not produced by the UI

The Clean footer reads these receipts (last clean, lifetime reclaimed) and labels the footer as demo history when any stored receipt is `fixtureSimulation`.

## Analyze Move to Trash

Analyze Move to Trash uses `FileManager.trashItem` in the current user context after the `Move to Trash?` confirmation. It is not a privileged helper action and does not go through Mole.

## Fixture executor is tests-only

`FixtureRootOperationTransport` mutates files only under an injected root using `openat` / `O_NOFOLLOW` / `unlinkat`. It is not constructed by `AppState` or `BurrowApp`.

## Helper / XPC not installed

`HelperAuthorizationBoundary` is a testable protocol boundary. There is no XPC service, no `SMJobBless`, and no helper install. Real privileged execution waits on an Xcode helper target, Developer ID, and a Mole plan that advertises `burrow-plan-v1`.

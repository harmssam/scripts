# Engine contract

Burrow talks to a pinned Mole 1.53 CLI through `MoleEngineClient`. The process runner launches `mo` with an argument array and a scrubbed environment. It never builds a shell command string.

The compatibility adapter is `MolePreviewAdapter_v1_53` (`supportedVersionMarker`: `Mole version 1.53.`). Other versions throw `incompatibleVersion`. Clean and Optimize previews fail closed (error, `nil` plan). Status and Analyze fail closed (error, no snapshot/report). Apps inventory uses `PreviewFallbacks.apps`.

## Commands Burrow actually runs

| Job | Argv | Output |
|---|---|---|
| Version | `mo --version` | First line is the engine version |
| Status | `mo status --json` | `StatusSnapshot` JSON |
| Analyze | `mo analyze --json <path>` | `AnalyzeReport` JSON |
| Clean preview | `mo clean --dry-run` | Mole 1.53 text; adapter requires `Dry Run Mode, Preview only, no deletions` and `Dry run complete - no changes made` |
| Optimize preview | `mo optimize --dry-run` | Mole 1.53 text; adapter requires `Dry Run Complete, No Changes Made` |
| Apps inventory | `mo uninstall --list` | Mole 1.53 JSON when stdout is a pipe. Do not pass `--list --json` (upstream rejects it) |

There are no `executeClean`, `executeOptimize`, or `executeUninstall` methods. The UI never launches `mo clean`, `mo optimize`, or `mo uninstall` without `--dry-run` or `--list`.

## Dry-run write caveat

Mole 1.53 `mo clean --dry-run` refreshes `~/.config/mole/clean-list.txt`. Burrow copy is “no cleanup performed,” not “the preview process writes nothing.”

## Structured protocol marker `burrow-plan-v1`

`executionPlanCapabilities` and `executionPlan(for:)` exist on the engine protocol. They run only when `mo --version` contains `burrow-plan-v1`. Stock Mole 1.53 does not. The UI does not call them.

If the marker is present, the client may request:

- `mo capabilities --json`
- `mo clean --plan-json`
- `mo optimize --plan-json`
- `mo uninstall --plan-json -- <application paths>`

Burrow must not probe invented flags on an unmarked engine.

## Demo vs live source badges

Preview plans carry `PreviewPlanSource`:

| Source | Badge |
|---|---|
| `moleCompatibilityAdapter` | `LIVE PREVIEW` |
| `demoFallback` | `UNAVAILABLE` |

Clean, Optimize, and Apps “run” is not an engine execute. It opens labeled `ExecutionFlowSheet` in `fixtureSimulation` mode (`DEMO SCENARIO · NO FILES WILL CHANGE`).

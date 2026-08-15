# workbench

macOS apps and utility scripts — all local, no accounts required.

| | |
|---|---|
| **Pulse** | Menu bar system monitor (network, CPU, GPU, thermals, memory) |
| **Harmless Budget** | Zero-based personal budgeting app — data stays on your Mac |
| **LLM Switchboard** | Local multi-plan LLM proxy (OpenAI-compat, failover, dashboard) |
| **Scripts** | Small CLI tools for dev and hardware testing |

Projects live under `apps/` (standalone applications) or `scripts/` (command-line utilities).

## Structure

```
apps/       # Menu bar apps and desktop applications
scripts/    # Utility scripts and small automation tools
```

## Applications

| App | Description | Latest | Releases |
|-----|-------------|--------|----------|
| [Pulse](apps/pulse/) | Real-time network, disk, CPU, GPU, temperature, and fan monitor for the menu bar | **0.3.1** | [Download](https://github.com/harmssam/workbench/releases/latest) |
| [Harmless Budget](apps/harmless-budget/) | Local-only zero-based budgeting — CSV import, rules, analytics | **0.1.0** | [Download](https://github.com/harmssam/workbench/releases) |
| [LLM Switchboard](apps/llm-switchboard/) | Personal local LLM proxy — multi-plan routing, failover, status dashboard | **0.1.0** | Run from source |

### Pulse

Install from [GitHub Releases](https://github.com/harmssam/workbench/releases) or build from source — see [apps/pulse/README.md](apps/pulse/README.md).

```bash
# Install a release build
# 1. Download Pulse-0.3.1-macos-arm64.zip from Releases
# 2. Unzip and copy to Applications:
cp -r Pulse.app /Applications/
open /Applications/Pulse.app
```

New releases are built automatically when a `pulse-v*` tag is pushed.

### Harmless Budget

Install from [GitHub Releases](https://github.com/harmssam/workbench/releases) or build from source — see [apps/harmless-budget/README.md](apps/harmless-budget/README.md).

```bash
# Install a release build
# 1. Download Harmless-Budget-0.1.0-macos-arm64.zip from Releases
# 2. Unzip and copy to Applications:
cp -r "Harmless Budget.app" /Applications/
open "/Applications/Harmless Budget.app"
```

New releases are built automatically when a `harmless-budget-v*` tag is pushed.

### LLM Switchboard

Local reverse proxy so agents/CLIs use one OpenAI-compatible endpoint while you route across multiple plans. See [apps/llm-switchboard/README.md](apps/llm-switchboard/README.md).

```bash
cd apps/llm-switchboard
npm install
mkdir -p ~/.llm-switchboard
cp config.example.yaml ~/.llm-switchboard/config.yaml
# edit gatewayKey + plans, then:
npm start
# dashboard: http://127.0.0.1:8787/
# clients:   base_url http://127.0.0.1:8787/v1  + gateway API key
```

Requires Node ≥ 22.5.

## Scripts

| Script | Description |
|--------|-------------|
| [heat-up.py](scripts/heat-up.py) | Stress CPU (all but one core) and GPU to raise system temperature for thermal testing |
| [gpu-stress.swift](scripts/gpu-stress.swift) | Metal compute shader used by `heat-up.py` on macOS |

```bash
./scripts/heat-up.py   # runs for 5 minutes or until Ctrl+C
```

Requires Python 3 and, on macOS, Swift for GPU stress.

## Requirements

- macOS 14+ (Apple Silicon) for GUI applications
- Toolchain details are documented in each project's README

## License

MIT — see [LICENSE](LICENSE).
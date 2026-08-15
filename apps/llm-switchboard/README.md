# LLM Switchboard

Personal local reverse proxy for LLMs. Coding agents and CLIs talk to **one** OpenAI-compatible endpoint; Switchboard routes across multiple plans/providers for capacity, failover, and reliability.

| Layer | Role |
|--------|------|
| Clients (OpenCode, CLIs, etc.) | Single OpenAI-compatible base URL + gateway key |
| Switchboard | Auth, model routes, equivalence groups, failover, activity log |
| Upstreams | Your plans/keys (OpenAI-compat, OpenCode, etc.) |

Binds to **127.0.0.1:8787** by default (local Mac only). No provider quota scraping — the dashboard tracks **errors and failover switches**.

**Version:** 0.1.0

## Requirements

| | |
|---|---|
| **Node** | **≥ 22.5** (uses built-in `node:sqlite`) |
| **OS** | macOS / Linux / any platform Node supports (designed for local Mac use) |

## Install

```bash
cd apps/llm-switchboard
npm install
```

## Config

Copy the example and edit:

```bash
mkdir -p ~/.llm-switchboard
cp config.example.yaml ~/.llm-switchboard/config.yaml
```

Set at least:

1. **`settings.gatewayKey`** — key clients use to call the switchboard (or `${SWITCHBOARD_GATEWAY_KEY}`).
2. **`plans`** — upstream base URLs and API keys.
3. **`groups` / `routes`** — how virtual models map to plans.

Default config path: `~/.llm-switchboard/config.yaml`. Override with `SWITCHBOARD_CONFIG`.

Secrets in YAML may use **`${ENV_VAR}`** placeholders (resolved at runtime for upstream calls and gateway auth).

## Run

```bash
npm start          # tsx src/index.ts
# or
npm run dev        # watch mode
```

## Dashboard

Open **http://127.0.0.1:8787/** and authenticate with the **gateway key** (same key clients use).

Pages: Overview, Plans, Equivalence groups, Model routes, Activity, Settings.

UI edits write back to the YAML config and reload; you can also edit the file directly.

## Point agents / CLIs at Switchboard

Configure any OpenAI-compatible client:

| Setting | Value |
|---------|--------|
| **Base URL** | `http://127.0.0.1:8787/v1` |
| **API key** | Your switchboard `gatewayKey` (not the provider key) |
| **Model** | A virtual model id from your **routes** (or whatever `defaultRoute` covers) |

Example for a generic OpenAI SDK client:

```text
base_url = http://127.0.0.1:8787/v1
api_key  = <gatewayKey>
model    = gpt-4o   # must match a route.model (or defaultRoute)
```

Public API:

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/chat/completions` | Chat (stream + non-stream) |
| `GET /v1/models` | List virtual models from routes |
| Auth | `Authorization: Bearer <gatewayKey>` |

## Concepts

```
Client request (virtual model)
        │
        ▼
   Model route  ──►  Equivalence group  ──►  Plans (credentials)
                           │
                    equal RR or priority
                    skip unhealthy / cooldown
```

| Concept | Meaning |
|---------|---------|
| **Plan** | One upstream credential set: name, base URL, API key, `openai-compat`, enabled |
| **Equivalence group** | Interchangeable plans; strategy `equal` (round-robin) or `priority` (ordered); cooldown after failures |
| **Model route** | Virtual model id clients request → group or pinned plan; optional `upstreamModel` rewrite |
| **Failover** | On retryable upstream errors (429, 502/503/504, timeout, connection, 401/403), try the next plan up to `maxFailoverAttempts` |
| **Activity** | Request outcomes, errors, and failover switches (SQLite under `~/.llm-switchboard/data/`) |

Mid-stream failover is **not** supported: a healthy plan is chosen before the stream starts.

### Optional `upstreamModel`

Clients always send the **virtual** model id. If the upstream expects a different name, set `upstreamModel` on the route:

```yaml
routes:
  - id: route-chat
    model: chat          # clients request this
    targetType: group
    targetId: chat-default
    upstreamModel: gpt-4o-mini   # sent to the provider
```

## Environment variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `SWITCHBOARD_CONFIG` | Path to config YAML | `~/.llm-switchboard/config.yaml` |
| `SWITCHBOARD_HOST` | Bind host | `127.0.0.1` (or `settings.host`) |
| `SWITCHBOARD_PORT` | Bind port | `8787` (or `settings.port`) |
| `SWITCHBOARD_DATA` | Events DB directory | `~/.llm-switchboard/data` |

YAML values may reference env vars as `${NAME}` (e.g. `apiKey: ${OPENAI_API_KEY}`).

## Events & metrics

- **No** scraping of OpenCode / provider portal quotas.
- Dashboard Activity shows **errors**, **routing choices**, and **failover switches**.
- Token usage is shown only if an upstream response includes it; otherwise "—".

## Development

```bash
npm test           # vitest
npm run typecheck  # tsc --noEmit
npm run dev        # watch server
```

## Project layout

```
apps/llm-switchboard/
├── config.example.yaml
├── src/
│   ├── index.ts          # entry
│   ├── app.ts            # Hono app
│   ├── config/           # load / save / schema / store
│   ├── proxy/            # /v1 chat + models + auth
│   ├── router/           # select + failover
│   ├── events/           # SQLite log + plan health
│   ├── admin/            # dashboard JSON API
│   └── dashboard/        # static UI (offline-capable)
└── tests/
```

## License

MIT — see the workbench [LICENSE](../../LICENSE).

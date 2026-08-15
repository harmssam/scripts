# LLM Switchboard — Progress Tracker

**Project:** Personal LLM proxy + small dashboard  
**Location:** `/Users/sharms/_github_repos/workbench`  
**Status:** v0.1 implemented  
**Last updated:** 2026-08-03

---

## Goal

A **personal** reverse proxy for LLMs so coding agents/CLIs see **one API**, while the backend routes across multiple plans/providers for **capacity**, **failover**, and **reliability**.

| Layer | Role |
|--------|------|
| Clients (OpenCode, CLIs, etc.) | Talk to a single OpenAI-compatible endpoint |
| Switchboard | Auth, routing, retries, failover, logging |
| Upstreams | Multiple plans/keys (OpenAI-compat, OpenCode, etc.) |

---

## Decisions (locked)

| Topic | Decision |
|--------|----------|
| Scope | Personal proxy, **local Mac only** |
| Clients | Coding agents / CLIs — OpenAI-compatible `/v1` + solid streaming |
| Upstreams (v1) | OpenAI-compatible APIs + OpenCode / provider-specific plans |
| Approach | **A — Custom gateway** (own proxy + routing + dashboard; not LiteLLM-first) |
| Config | **UI and file stay in sync** (edit either side) |
| Usage metrics | **No** scraping OpenCode / Pushmark quotas. Track **errors + routing switches** instead. Optional: show token usage *if* upstream returns it; otherwise "—" |
| Mid-stream failover | **No** — pick healthy upstream before stream; log failure if stream already started |
| Tech stack | TypeScript, Node 20+, Hono, better-sqlite3, Vitest, vanilla dashboard |
| Config source of truth | YAML (`~/.llm-switchboard/config.yaml`); SQLite for events only |
| Project name / path | `apps/llm-switchboard` |
| Bind defaults | `127.0.0.1:8787` |
| OpenCode in v1 | Use `openai-compat` provider type with custom base URL |

### Rejected / deferred for v1

- Multi-user auth, billing, spend dashboards from provider portals  
- Mid-stream provider hop  
- Managed cloud deploy (may revisit later; design local-first)  
- LiteLLM-as-core (Approach B) unless we hit protocol pain  

---

## Core concepts

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
| **Plan** | One upstream credential set: name, base URL, API key, provider type, enabled |
| **Equivalence group** | Plans that are interchangeable; strategy = equal priority or ordered priority |
| **Model route** | Virtual model id clients request → group or pinned plan |
| **Event log** | Request outcomes, errors, failovers, cooldowns (dashboard “activity”) |

---

## Design sections

### Section 1 — Architecture — **Approved**

- Single local process: proxy + config + dashboard  
- Plans → equivalence groups → model routes  
- Gateway key for clients; real keys only on switchboard  

### Section 2 — Dashboard & API — **Approved** (with usage note)

**Public API (agents)**

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/chat/completions` | Main path (stream + non-stream) |
| `GET /v1/models` | List virtual models from routes |
| Auth | Single gateway API key |

Example bind: `http://127.0.0.1:8787`

**Dashboard pages**

1. **Overview** — up/down, counts (requests / success / fail / failovers), plan health chips (OK / degraded / cooldown)  
2. **Plans** — CRUD, enable/disable, masked keys, test connection  
3. **Equivalence groups** — members, equal vs priority, cooldown after failures  
4. **Model routes** — virtual id → group/plan; optional pin; default for unknown  
5. **Activity / events** — request log, upstream chosen, errors, **failover chains**  
6. **Settings** — gateway key, timeouts, max failover attempts, export/import YAML, data dir  

**Failover rules**

- Retryable: 429, 502/503/504, timeout, connection errors  
- Default: try next plan on 401/403; stop on 400  
- Max attempts configurable; log every switch  

**Config dual-write**

- UI edits write config + reload  
- YAML edits picked up (reload or file watch)  
- Optional `${ENV_VAR}` for secrets in file  

### Section 3 — Tech stack — **Locked for implementation**

See Decisions table. Plan: `docs/superpowers/plans/2026-08-03-llm-switchboard.md`

### Section 4 — OpenCode / packaging — **Deferred details**

OpenCode plans as openai-compat endpoints. launchd packaging later.

---

## Implementation checklist

- [x] Implementation plan written  
- [x] Scaffold project under `workbench`  
- [x] Config model (plans, groups, routes) + YAML round-trip  
- [x] OpenAI-compatible proxy (`chat/completions`, `models`, streaming)  
- [x] Router: equal / priority + cooldown + failover  
- [x] Event log (errors + routing switches)  
- [x] Dashboard UI (overview, plans, groups, routes, activity, settings)  
- [x] Gateway auth key  
- [x] Local run docs (point OpenCode / CLIs at proxy)  
- [x] Smoke tests: multi-plan failover, stream success path  

---

## Open questions

1. **OpenCode upstream shape** — exact base URL / auth / model names (configure as openai-compat when known).  

---

## Progress log

| Date | Note |
|------|------|
| 2026-08-03 | Idea: multi-plan LLM switchboard, single client API, failover on usage errors |
| 2026-08-03 | Constraints: local Mac, coding agents, OpenAI-compat + OpenCode, UI+file config |
| 2026-08-03 | Chose custom gateway (Approach A); dashboard status without provider quota scraping |
| 2026-08-03 | Sections 1–2 approved; this progress file created under `workbench/docs/` |
| 2026-08-03 | Locked stack (TS/Hono/SQLite/YAML); plan written; starting SDD implementation on `feat/llm-switchboard` |
| 2026-08-03 | v0.1: proxy, router/failover, events, dashboard, tests green; README + workbench listing + example config |

---

## Related approaches (reference)

| Approach | Summary | Status |
|----------|---------|--------|
| **A. Custom gateway** | Own proxy + routing mental model + dashboard | **Selected** |
| B. LiteLLM + thin UI | Compile config into LiteLLM | Not chosen for v1 |
| C. YAML + minimal status | Config-only, weak UX | Not chosen |

---

## How to use this file

- Update **Status** and **Last updated** when phase changes.  
- Check off **Implementation checklist** items as they land.  
- Append rows to **Progress log** for decisions and milestones.  
- Keep **Open questions** current; move answers into **Decisions** when locked.  

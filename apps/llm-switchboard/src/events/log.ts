import type { DatabaseSync } from 'node:sqlite';
import { openEventsDb } from './db.js';

export type EventType =
  | 'request_start'
  | 'upstream_attempt'
  | 'upstream_success'
  | 'upstream_error'
  | 'failover'
  | 'request_success'
  | 'request_error'
  | 'cooldown_start'
  | 'cooldown_end';

export interface SwitchEvent {
  id: number;
  ts: number;
  type: EventType;
  requestId: string;
  virtualModel?: string;
  planId?: string;
  message?: string;
  statusCode?: number;
  latencyMs?: number;
  promptTokens?: number | null;
  completionTokens?: number | null;
  meta?: string; // JSON blob optional
}

export interface EventStore {
  append(e: Omit<SwitchEvent, 'id' | 'ts'> & { ts?: number }): void;
  list(limit?: number): SwitchEvent[];
  stats(sinceMs?: number): {
    requests: number;
    successes: number;
    failures: number;
    failovers: number;
  };
}

interface EventRow {
  id: number;
  ts: number;
  type: string;
  request_id: string;
  virtual_model: string | null;
  plan_id: string | null;
  message: string | null;
  status_code: number | null;
  latency_ms: number | null;
  prompt_tokens: number | null;
  completion_tokens: number | null;
  meta: string | null;
}

function rowToEvent(row: EventRow): SwitchEvent {
  const e: SwitchEvent = {
    id: row.id,
    ts: row.ts,
    type: row.type as EventType,
    requestId: row.request_id,
  };
  if (row.virtual_model != null) e.virtualModel = row.virtual_model;
  if (row.plan_id != null) e.planId = row.plan_id;
  if (row.message != null) e.message = row.message;
  if (row.status_code != null) e.statusCode = row.status_code;
  if (row.latency_ms != null) e.latencyMs = row.latency_ms;
  // DB null means unset; only set optional fields when non-null
  if (row.prompt_tokens != null) e.promptTokens = row.prompt_tokens;
  if (row.completion_tokens != null) e.completionTokens = row.completion_tokens;
  if (row.meta != null) e.meta = row.meta;
  return e;
}

export interface EventStoreHandle extends EventStore {
  /** Underlying DatabaseSync (for tests / close). */
  db(): DatabaseSync;
  close(): void;
}

/**
 * Create an EventStore backed by SQLite.
 * Pass a path string, or an already-open DatabaseSync (e.g. `:memory:` via openEventsDb).
 */
export function createEventStore(dbOrPath?: DatabaseSync | string): EventStoreHandle {
  const ownsDb = typeof dbOrPath === 'string' || dbOrPath === undefined;
  const db: DatabaseSync =
    typeof dbOrPath === 'object' && dbOrPath !== null
      ? dbOrPath
      : openEventsDb(typeof dbOrPath === 'string' ? dbOrPath : undefined);

  const insert = db.prepare(`
    INSERT INTO events (
      ts, type, request_id, virtual_model, plan_id, message,
      status_code, latency_ms, prompt_tokens, completion_tokens, meta
    ) VALUES (
      ?, ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?
    )
  `);

  const listStmt = db.prepare(`
    SELECT
      id, ts, type, request_id, virtual_model, plan_id, message,
      status_code, latency_ms, prompt_tokens, completion_tokens, meta
    FROM events
    ORDER BY id DESC
    LIMIT ?
  `);

  const countByType = db.prepare(`
    SELECT type, COUNT(*) AS n
    FROM events
    WHERE (? IS NULL OR ts >= ?)
    GROUP BY type
  `);

  return {
    append(e) {
      const ts = e.ts ?? Date.now();
      insert.run(
        ts,
        e.type,
        e.requestId,
        e.virtualModel ?? null,
        e.planId ?? null,
        e.message ?? null,
        e.statusCode ?? null,
        e.latencyMs ?? null,
        e.promptTokens === undefined ? null : e.promptTokens,
        e.completionTokens === undefined ? null : e.completionTokens,
        e.meta ?? null,
      );
    },

    list(limit = 100) {
      const n = Math.max(0, Math.floor(limit));
      const rows = listStmt.all(n) as unknown as EventRow[];
      return rows.map(rowToEvent);
    },

    stats(sinceMs) {
      const since = sinceMs === undefined ? null : sinceMs;
      const rows = countByType.all(since, since) as unknown as Array<{
        type: string;
        n: number | bigint;
      }>;
      const byType = new Map<string, number>();
      for (const r of rows) {
        byType.set(r.type, Number(r.n));
      }
      return {
        requests: byType.get('request_start') ?? 0,
        successes: byType.get('request_success') ?? 0,
        failures: byType.get('request_error') ?? 0,
        failovers: byType.get('failover') ?? 0,
      };
    },

    db() {
      return db;
    },

    close() {
      if (ownsDb) {
        db.close();
      }
    },
  };
}

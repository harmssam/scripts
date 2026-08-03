import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { dataPath } from '../env.js';

export const EVENTS_SCHEMA = `
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  type TEXT NOT NULL,
  request_id TEXT NOT NULL,
  virtual_model TEXT,
  plan_id TEXT,
  message TEXT,
  status_code INTEGER,
  latency_ms INTEGER,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  meta TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_request_id ON events(request_id);
`;

/** Default path: `${dataPath()}/events.db`. */
export function defaultEventsDbPath(): string {
  return join(dataPath(), 'events.db');
}

/**
 * Open (or create) the events SQLite DB and ensure schema.
 * Uses Node's built-in `node:sqlite` (DatabaseSync).
 */
export function openEventsDb(dbPath: string = defaultEventsDbPath()): DatabaseSync {
  if (dbPath !== ':memory:') {
    mkdirSync(dirname(dbPath), { recursive: true });
  }
  const db = new DatabaseSync(dbPath);
  db.exec(EVENTS_SCHEMA);
  return db;
}

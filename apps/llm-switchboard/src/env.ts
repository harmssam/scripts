import { homedir } from 'node:os';
import { join } from 'node:path';

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8787;

/** Root directory for config and data (~/.llm-switchboard). */
export function switchboardHome(): string {
  return join(homedir(), '.llm-switchboard');
}

/** Default config path; override with SWITCHBOARD_CONFIG. */
export function configPath(): string {
  return process.env.SWITCHBOARD_CONFIG ?? join(switchboardHome(), 'config.yaml');
}

/** Default data directory for events DB (~/.llm-switchboard/data/). */
export function dataPath(): string {
  return process.env.SWITCHBOARD_DATA ?? join(switchboardHome(), 'data');
}

/** Bind host; default 127.0.0.1 only (no LAN unless SWITCHBOARD_HOST set). */
export function host(): string {
  return process.env.SWITCHBOARD_HOST ?? DEFAULT_HOST;
}

/** Bind port; default 8787. Override with SWITCHBOARD_PORT. */
export function port(): number {
  const raw = process.env.SWITCHBOARD_PORT;
  if (raw === undefined || raw === '') return DEFAULT_PORT;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0 || n > 65535) {
    throw new Error(`Invalid SWITCHBOARD_PORT: ${raw}`);
  }
  return Math.floor(n);
}

export const defaults = {
  host: DEFAULT_HOST,
  port: DEFAULT_PORT,
  requestTimeoutMs: 120_000,
  maxFailoverAttempts: 3,
  cooldownSeconds: 120,
} as const;

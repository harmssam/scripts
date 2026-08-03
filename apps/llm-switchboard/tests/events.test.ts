import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { openEventsDb } from '../src/events/db.js';
import { createHealthTracker } from '../src/events/health.js';
import { createEventStore } from '../src/events/log.js';

const tmpDirs: string[] = [];

afterEach(() => {
  for (const d of tmpDirs) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
  tmpDirs.length = 0;
});

function tempDbPath(): string {
  const dir = mkdtempSync(join(tmpdir(), 'llm-switchboard-events-'));
  tmpDirs.push(dir);
  return join(dir, 'events.db');
}

describe('EventStore', () => {
  it('append + list returns newest first with auto id/ts', () => {
    const store = createEventStore(openEventsDb(':memory:'));
    store.append({
      type: 'request_start',
      requestId: 'r1',
      virtualModel: 'gpt-test',
      ts: 1000,
    });
    store.append({
      type: 'upstream_attempt',
      requestId: 'r1',
      planId: 'p1',
      ts: 1001,
    });
    store.append({
      type: 'request_success',
      requestId: 'r1',
      planId: 'p1',
      latencyMs: 42,
      promptTokens: 10,
      completionTokens: 5,
      ts: 1100,
    });

    const all = store.list();
    expect(all).toHaveLength(3);
    expect(all[0].type).toBe('request_success');
    expect(all[0].id).toBe(3);
    expect(all[0].latencyMs).toBe(42);
    expect(all[0].promptTokens).toBe(10);
    expect(all[0].completionTokens).toBe(5);
    expect(all[2].type).toBe('request_start');
    expect(all[2].virtualModel).toBe('gpt-test');

    expect(store.list(1)).toHaveLength(1);
    expect(store.list(1)[0].type).toBe('request_success');
    store.close();
  });

  it('stats counts request/success/failure/failover since timestamp', () => {
    const store = createEventStore(openEventsDb(':memory:'));
    store.append({ type: 'request_start', requestId: 'a', ts: 100 });
    store.append({ type: 'request_success', requestId: 'a', ts: 110 });
    store.append({ type: 'request_start', requestId: 'b', ts: 200 });
    store.append({ type: 'failover', requestId: 'b', planId: 'p1', ts: 205 });
    store.append({ type: 'request_error', requestId: 'b', ts: 210 });
    store.append({ type: 'request_start', requestId: 'c', ts: 300 });
    store.append({ type: 'request_success', requestId: 'c', ts: 310 });

    expect(store.stats()).toEqual({
      requests: 3,
      successes: 2,
      failures: 1,
      failovers: 1,
    });

    expect(store.stats(200)).toEqual({
      requests: 2,
      successes: 1,
      failures: 1,
      failovers: 1,
    });

    expect(store.stats(301)).toEqual({
      requests: 0,
      successes: 1,
      failures: 0,
      failovers: 0,
    });
    store.close();
  });

  it('persists to file path across reopen', () => {
    const path = tempDbPath();
    const store1 = createEventStore(path);
    store1.append({
      type: 'cooldown_start',
      requestId: 'r',
      planId: 'p1',
      message: 'too many failures',
      statusCode: 429,
      ts: 50,
      meta: JSON.stringify({ reason: '429' }),
    });
    store1.close();

    const store2 = createEventStore(path);
    const rows = store2.list();
    expect(rows).toHaveLength(1);
    expect(rows[0].type).toBe('cooldown_start');
    expect(rows[0].statusCode).toBe(429);
    expect(rows[0].meta).toBe(JSON.stringify({ reason: '429' }));
    store2.close();
  });

  it('defaults ts when omitted', () => {
    const store = createEventStore(openEventsDb(':memory:'));
    const before = Date.now();
    store.append({ type: 'request_start', requestId: 'x' });
    const after = Date.now();
    const [ev] = store.list(1);
    expect(ev.ts).toBeGreaterThanOrEqual(before);
    expect(ev.ts).toBeLessThanOrEqual(after);
    store.close();
  });
});

describe('HealthTracker', () => {
  it('ok → degraded after one failure → cooldown after two', () => {
    let t = 1_000_000;
    const health = createHealthTracker({ now: () => t });

    expect(health.status('p1')).toBe('ok');
    expect(health.isAvailable('p1')).toBe(true);

    health.recordFailure('p1', 120);
    expect(health.status('p1')).toBe('degraded');
    expect(health.isAvailable('p1')).toBe(true);
    expect(health.snapshot().p1.failures).toBe(1);

    health.recordFailure('p1', 120);
    expect(health.status('p1')).toBe('cooldown');
    expect(health.isAvailable('p1')).toBe(false);
    expect(health.snapshot().p1.cooldownUntil).toBe(t + 120_000);
  });

  it('429 immediately starts cooldown', () => {
    let t = 5_000;
    const health = createHealthTracker({ now: () => t });

    health.recordFailure('plan-a', 60, 429);
    expect(health.status('plan-a')).toBe('cooldown');
    expect(health.isAvailable('plan-a')).toBe(false);
    expect(health.snapshot()['plan-a']).toEqual({
      status: 'cooldown',
      failures: 1,
      cooldownUntil: 5_000 + 60_000,
    });
  });

  it('success resets failures and clears cooldown', () => {
    let t = 0;
    const health = createHealthTracker({ now: () => t });
    health.recordFailure('p', 10);
    health.recordFailure('p', 10);
    expect(health.status('p')).toBe('cooldown');

    health.recordSuccess('p');
    expect(health.status('p')).toBe('ok');
    expect(health.isAvailable('p')).toBe(true);
    expect(health.snapshot().p).toEqual({ status: 'ok', failures: 0 });
  });

  it('cooldown expires by time without success', () => {
    let t = 1000;
    const health = createHealthTracker({ now: () => t });
    health.recordFailure('p', 2, 429); // cooldown 2s
    expect(health.isAvailable('p')).toBe(false);

    t = 1000 + 2000; // exactly at end
    expect(health.isAvailable('p')).toBe(true);
    // still degraded (failure count retained) after cooldown ends
    expect(health.status('p')).toBe('degraded');
    expect(health.snapshot().p.cooldownUntil).toBeUndefined();
  });

  it('tracks multiple plans independently', () => {
    const health = createHealthTracker({ now: () => 0 });
    health.recordFailure('a', 1);
    health.recordFailure('b', 1, 429);
    expect(health.status('a')).toBe('degraded');
    expect(health.status('b')).toBe('cooldown');
    expect(Object.keys(health.snapshot()).sort()).toEqual(['a', 'b']);
  });
});

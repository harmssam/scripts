import { afterEach, describe, expect, it } from 'vitest';
import { createHealthTracker } from '../src/events/health.js';
import { resetRoundRobinCounters, resolvePlanCandidates } from '../src/router/select.js';
import type { Config, Plan } from '../src/types.js';

afterEach(() => {
  resetRoundRobinCounters();
});

function plan(id: string, enabled = true): Plan {
  return {
    id,
    name: id,
    baseUrl: `https://example.com/${id}/v1`,
    apiKey: 'k',
    providerType: 'openai-compat',
    enabled,
  };
}

function baseConfig(overrides?: Partial<Config>): Config {
  return {
    version: 1,
    settings: {
      gatewayKey: 'gw',
      requestTimeoutMs: 120000,
      maxFailoverAttempts: 3,
      host: '127.0.0.1',
      port: 8787,
    },
    plans: [plan('a'), plan('b'), plan('c')],
    groups: [
      {
        id: 'eq',
        name: 'Equal group',
        strategy: 'equal',
        planIds: ['a', 'b', 'c'],
        cooldownSeconds: 120,
      },
      {
        id: 'pri',
        name: 'priority group',
        strategy: 'priority',
        planIds: ['a', 'b', 'c'],
        cooldownSeconds: 60,
      },
    ],
    routes: [
      {
        id: 'r-eq',
        model: 'model-equal',
        targetType: 'group',
        targetId: 'eq',
      },
      {
        id: 'r-pri',
        model: 'model-priority',
        targetType: 'group',
        targetId: 'pri',
      },
      {
        id: 'r-pin',
        model: 'model-pin',
        targetType: 'plan',
        targetId: 'b',
      },
    ],
    defaultRoute: { targetType: 'group', targetId: 'eq' },
    ...overrides,
  };
}

describe('resolvePlanCandidates', () => {
  it('equal strategy cycles starting plan via RR', () => {
    const config = baseConfig();
    const health = createHealthTracker();

    const r0 = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);
    const r1 = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);
    const r2 = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);
    const r3 = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);

    expect(r0).toEqual(['a', 'b', 'c']);
    expect(r1).toEqual(['b', 'c', 'a']);
    expect(r2).toEqual(['c', 'a', 'b']);
    expect(r3).toEqual(['a', 'b', 'c']);
  });

  it('priority strategy keeps planIds order', () => {
    const config = baseConfig();
    const health = createHealthTracker();

    const r0 = resolvePlanCandidates(config, 'model-priority', health).map((c) => c.plan.id);
    const r1 = resolvePlanCandidates(config, 'model-priority', health).map((c) => c.plan.id);

    expect(r0).toEqual(['a', 'b', 'c']);
    expect(r1).toEqual(['a', 'b', 'c']);
  });

  it('pins to a single plan when route targetType is plan', () => {
    const config = baseConfig();
    const health = createHealthTracker();

    const cands = resolvePlanCandidates(config, 'model-pin', health);
    expect(cands).toHaveLength(1);
    expect(cands[0]!.plan.id).toBe('b');
    expect(cands[0]!.reason).toContain('plan b');
  });

  it('returns empty for unknown model with no defaultRoute', () => {
    const config = baseConfig({ defaultRoute: null, routes: [] });
    const health = createHealthTracker();
    expect(resolvePlanCandidates(config, 'nope', health)).toEqual([]);
  });

  it('falls back to defaultRoute when model has no specific route', () => {
    const config = baseConfig();
    const health = createHealthTracker();
    const ids = resolvePlanCandidates(config, 'some-other-model', health).map((c) => c.plan.id);
    expect(ids).toEqual(['a', 'b', 'c']);
    expect(resolvePlanCandidates(config, 'some-other-model', health)[0]!.reason).toMatch(
      /defaultRoute/
    );
  });

  it('skips plans in cooldown', () => {
    const config = baseConfig();
    let t = 1_000_000;
    const health = createHealthTracker({ now: () => t });
    // force cooldown on b
    health.recordFailure('b', 120, 429);
    expect(health.isAvailable('b')).toBe(false);

    const ids = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);
    expect(ids).toEqual(['a', 'c']);
    expect(ids).not.toContain('b');
  });

  it('skips disabled plans', () => {
    const config = baseConfig({
      plans: [plan('a'), plan('b', false), plan('c')],
    });
    const health = createHealthTracker();
    const ids = resolvePlanCandidates(config, 'model-priority', health).map((c) => c.plan.id);
    expect(ids).toEqual(['a', 'c']);
  });

  it('pin to cooldown plan yields empty', () => {
    const config = baseConfig();
    const health = createHealthTracker({ now: () => 0 });
    health.recordFailure('b', 60, 429);
    expect(resolvePlanCandidates(config, 'model-pin', health)).toEqual([]);
  });

  it('equal RR rotates only over available plans', () => {
    const config = baseConfig();
    const health = createHealthTracker({ now: () => 0 });
    health.recordFailure('a', 60, 429); // a unavailable

    const r0 = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);
    const r1 = resolvePlanCandidates(config, 'model-equal', health).map((c) => c.plan.id);

    expect(r0).toEqual(['b', 'c']);
    expect(r1).toEqual(['c', 'b']);
  });

  it('missing group or plan target yields empty', () => {
    const config = baseConfig({
      routes: [
        { id: 'r1', model: 'ghost-group', targetType: 'group', targetId: 'nope' },
        { id: 'r2', model: 'ghost-plan', targetType: 'plan', targetId: 'nope' },
      ],
      defaultRoute: null,
    });
    const health = createHealthTracker();
    expect(resolvePlanCandidates(config, 'ghost-group', health)).toEqual([]);
    expect(resolvePlanCandidates(config, 'ghost-plan', health)).toEqual([]);
  });
});

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createHonoApp } from '../src/app.js';
import { createConfigStore } from '../src/config/store.js';
import { openEventsDb } from '../src/events/db.js';
import { createHealthTracker } from '../src/events/health.js';
import { createEventStore } from '../src/events/log.js';
import type { Config } from '../src/types.js';
import { maskConfig } from '../src/admin/routes.js';

const GATEWAY_KEY = 'admin-test-key';

function baseConfig(): Config {
  return {
    version: 1,
    settings: {
      gatewayKey: GATEWAY_KEY,
      requestTimeoutMs: 5000,
      maxFailoverAttempts: 3,
      host: '127.0.0.1',
      port: 8787,
    },
    plans: [
      {
        id: 'plan-a',
        name: 'Plan A',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'secret-key-a',
        providerType: 'openai-compat',
        enabled: true,
      },
    ],
    groups: [
      {
        id: 'g1',
        name: 'Group 1',
        strategy: 'equal',
        planIds: ['plan-a'],
        cooldownSeconds: 60,
      },
    ],
    routes: [
      {
        id: 'r1',
        model: 'virt-model',
        targetType: 'group',
        targetId: 'g1',
      },
    ],
    defaultRoute: null,
  };
}

describe('maskConfig', () => {
  it('masks api keys and gateway key', () => {
    const m = maskConfig(baseConfig()) as {
      settings: { gatewayKey: string; gatewayKeySet: boolean };
      plans: Array<{ apiKey: string; apiKeySet: boolean }>;
    };
    expect(m.settings.gatewayKey).toBe('***');
    expect(m.settings.gatewayKeySet).toBe(true);
    expect(m.plans[0]!.apiKey).toBe('***');
    expect(m.plans[0]!.apiKeySet).toBe(true);
  });
});

describe('admin API', () => {
  let tmpDir: string;
  let events: ReturnType<typeof createEventStore>;
  let store: ReturnType<typeof createConfigStore>;
  let app: ReturnType<typeof createHonoApp>;
  let health: ReturnType<typeof createHealthTracker>;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'sb-admin-'));
    const cfgPath = join(tmpDir, 'config.yaml');
    store = createConfigStore(cfgPath, baseConfig());
    events = createEventStore(openEventsDb(':memory:'));
    health = createHealthTracker();
    app = createHonoApp({ configStore: store, events, health });
  });

  afterEach(() => {
    events.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
    return {
      Authorization: `Bearer ${GATEWAY_KEY}`,
      'Content-Type': 'application/json',
      ...extra,
    };
  }

  async function json(
    method: string,
    path: string,
    body?: unknown,
    headers?: Record<string, string>
  ) {
    const res = await app.request(path, {
      method,
      headers: headers ?? authHeaders(),
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let data: unknown = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }
    return { res, data, status: res.status };
  }

  it('rejects unauthenticated admin requests', async () => {
    const { status } = await json('GET', '/admin/api/overview', undefined, {});
    expect(status).toBe(401);
  });

  it('accepts X-Switchboard-Key auth', async () => {
    const { status, data } = await json('GET', '/admin/api/overview', undefined, {
      'X-Switchboard-Key': GATEWAY_KEY,
    });
    expect(status).toBe(200);
    expect(data).toMatchObject({
      stats: expect.any(Object),
      plans: expect.any(Array),
    });
  });

  it('GET /admin/api/overview returns stats and plan health', async () => {
    events.append({ type: 'request_start', requestId: 'req-1' });
    events.append({ type: 'failover', requestId: 'req-1', planId: 'plan-a' });
    health.recordFailure('plan-a', 60);

    const { status, data } = await json('GET', '/admin/api/overview');
    expect(status).toBe(200);
    const body = data as {
      stats: { requests: number; failovers: number };
      plans: Array<{ id: string; status: string }>;
      health: Record<string, unknown>;
    };
    expect(body.stats.requests).toBe(1);
    expect(body.stats.failovers).toBe(1);
    expect(body.plans.find((p) => p.id === 'plan-a')).toBeTruthy();
    expect(body.health['plan-a']).toBeTruthy();
  });

  it('GET /admin/api/config masks secrets', async () => {
    const { status, data } = await json('GET', '/admin/api/config');
    expect(status).toBe(200);
    const cfg = data as {
      settings: { gatewayKey: string };
      plans: Array<{ apiKey: string; apiKeySet: boolean }>;
    };
    expect(cfg.settings.gatewayKey).toBe('***');
    expect(cfg.plans[0]!.apiKey).toBe('***');
    expect(cfg.plans[0]!.apiKeySet).toBe(true);
    // store still has real key
    expect(store.get().plans[0]!.apiKey).toBe('secret-key-a');
  });

  it('PUT /admin/api/config replaces config and preserves masked keys', async () => {
    const current = store.get();
    const { status, data } = await json('PUT', '/admin/api/config', {
      version: 1,
      settings: { ...current.settings, gatewayKey: '***', requestTimeoutMs: 9000 },
      plans: current.plans.map((p) => ({ ...p, apiKey: '***', name: 'Renamed' })),
      groups: current.groups,
      routes: current.routes,
      defaultRoute: null,
    });
    expect(status).toBe(200);
    expect(store.get().settings.requestTimeoutMs).toBe(9000);
    expect(store.get().plans[0]!.name).toBe('Renamed');
    expect(store.get().plans[0]!.apiKey).toBe('secret-key-a');
    expect(store.get().settings.gatewayKey).toBe(GATEWAY_KEY);
    const masked = data as { plans: Array<{ apiKey: string }> };
    expect(masked.plans[0]!.apiKey).toBe('***');
  });

  it('CRUD plans', async () => {
    // create
    const created = await json('POST', '/admin/api/plans', {
      id: 'plan-b',
      name: 'Plan B',
      baseUrl: 'https://b.example.com/v1',
      apiKey: 'key-b',
      providerType: 'openai-compat',
      enabled: true,
    });
    expect(created.status).toBe(201);
    expect(store.get().plans.map((p) => p.id)).toContain('plan-b');

    // list
    const list = await json('GET', '/admin/api/plans');
    expect(list.status).toBe(200);
    expect((list.data as unknown[]).length).toBe(2);

    // update
    const updated = await json('PUT', '/admin/api/plans/plan-b', {
      name: 'Plan B2',
      baseUrl: 'https://b2.example.com/v1',
    });
    expect(updated.status).toBe(200);
    expect(store.get().plans.find((p) => p.id === 'plan-b')!.name).toBe('Plan B2');
    // key preserved
    expect(store.get().plans.find((p) => p.id === 'plan-b')!.apiKey).toBe('key-b');

    // delete (not referenced)
    const del = await json('DELETE', '/admin/api/plans/plan-b');
    expect(del.status).toBe(200);
    expect(store.get().plans.map((p) => p.id)).not.toContain('plan-b');

    // cannot delete referenced plan
    const delRef = await json('DELETE', '/admin/api/plans/plan-a');
    expect(delRef.status).toBe(400);
  });

  it('CRUD groups', async () => {
    // need a free plan for a new group without conflicting — use plan-a already in g1
    const created = await json('POST', '/admin/api/groups', {
      id: 'g2',
      name: 'Group 2',
      strategy: 'priority',
      planIds: ['plan-a'],
      cooldownSeconds: 30,
    });
    expect(created.status).toBe(201);

    const list = await json('GET', '/admin/api/groups');
    expect((list.data as unknown[]).length).toBe(2);

    const updated = await json('PUT', '/admin/api/groups/g2', {
      name: 'G2',
      strategy: 'equal',
      planIds: ['plan-a'],
      cooldownSeconds: 90,
    });
    expect(updated.status).toBe(200);
    expect(store.get().groups.find((g) => g.id === 'g2')!.cooldownSeconds).toBe(90);

    const del = await json('DELETE', '/admin/api/groups/g2');
    expect(del.status).toBe(200);

    // cannot delete referenced group
    const delRef = await json('DELETE', '/admin/api/groups/g1');
    expect(delRef.status).toBe(400);
  });

  it('CRUD routes', async () => {
    const created = await json('POST', '/admin/api/routes', {
      id: 'r2',
      model: 'other-model',
      targetType: 'plan',
      targetId: 'plan-a',
      upstreamModel: 'gpt-real',
    });
    expect(created.status).toBe(201);

    const list = await json('GET', '/admin/api/routes');
    expect((list.data as unknown[]).length).toBe(2);

    const updated = await json('PUT', '/admin/api/routes/r2', {
      model: 'other-v2',
      targetType: 'plan',
      targetId: 'plan-a',
    });
    expect(updated.status).toBe(200);
    expect(store.get().routes.find((r) => r.id === 'r2')!.model).toBe('other-v2');

    const del = await json('DELETE', '/admin/api/routes/r2');
    expect(del.status).toBe(200);
    expect(store.get().routes.map((r) => r.id)).not.toContain('r2');
  });

  it('GET /admin/api/events returns recent events', async () => {
    events.append({ type: 'request_start', requestId: 'e1', virtualModel: 'm' });
    events.append({
      type: 'upstream_error',
      requestId: 'e1',
      planId: 'plan-a',
      message: 'boom',
      statusCode: 500,
    });
    events.append({ type: 'failover', requestId: 'e1', planId: 'plan-a', message: 'switch' });

    const { status, data } = await json('GET', '/admin/api/events?limit=10');
    expect(status).toBe(200);
    const list = data as Array<{ type: string }>;
    expect(list.length).toBe(3);
    expect(list.some((e) => e.type === 'failover')).toBe(true);
  });

  it('PUT /admin/api/settings updates settings', async () => {
    const { status, data } = await json('PUT', '/admin/api/settings', {
      requestTimeoutMs: 42_000,
      maxFailoverAttempts: 5,
      gatewayKey: '***',
    });
    expect(status).toBe(200);
    expect(store.get().settings.requestTimeoutMs).toBe(42_000);
    expect(store.get().settings.maxFailoverAttempts).toBe(5);
    expect(store.get().settings.gatewayKey).toBe(GATEWAY_KEY);
    const body = data as { gatewayKey: string; requestTimeoutMs: number };
    expect(body.gatewayKey).toBe('***');
    expect(body.requestTimeoutMs).toBe(42_000);
  });

  it('GET /admin/api/meta returns config path', async () => {
    const { status, data } = await json('GET', '/admin/api/meta');
    expect(status).toBe(200);
    expect((data as { configPath: string }).configPath).toContain('config.yaml');
  });

  it('POST /admin/api/plans/:id/test probes models endpoint', async () => {
    const hits = { n: 0 };
    const server = http.createServer((req, res) => {
      hits.n += 1;
      if (req.method === 'GET' && req.url === '/v1/models') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ data: [] }));
        return;
      }
      res.writeHead(404);
      res.end();
    });
    await new Promise<void>((resolve, reject) => {
      server.listen(0, '127.0.0.1', () => resolve());
      server.on('error', reject);
    });
    const addr = server.address() as AddressInfo;
    const baseUrl = `http://127.0.0.1:${addr.port}/v1`;

    await store.update((cfg) => ({
      ...cfg,
      plans: cfg.plans.map((p) =>
        p.id === 'plan-a' ? { ...p, baseUrl } : p
      ),
    }));

    try {
      const { status, data } = await json('POST', '/admin/api/plans/plan-a/test');
      expect(status).toBe(200);
      const body = data as { ok: boolean; status: number };
      expect(body.ok).toBe(true);
      expect(body.status).toBe(200);
      expect(hits.n).toBe(1);
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
    }
  });

  it('POST plan test returns ok:false without hard fail on connection error', async () => {
    await store.update((cfg) => ({
      ...cfg,
      plans: cfg.plans.map((p) =>
        p.id === 'plan-a'
          ? { ...p, baseUrl: 'http://127.0.0.1:1/v1' }
          : p
      ),
    }));
    const { status, data } = await json('POST', '/admin/api/plans/plan-a/test');
    expect(status).toBe(200);
    const body = data as { ok: boolean; error: string };
    expect(body.ok).toBe(false);
    expect(body.error).toBeTruthy();
  });

  it('serves dashboard static files', async () => {
    const index = await app.request('/');
    expect(index.status).toBe(200);
    const html = await index.text();
    expect(html).toContain('LLM Switchboard');
    expect(html).toContain('/app.js');

    const js = await app.request('/app.js');
    expect(js.status).toBe(200);
    expect(js.headers.get('content-type')).toMatch(/javascript/);

    const css = await app.request('/styles.css');
    expect(css.status).toBe(200);
    expect(css.headers.get('content-type')).toMatch(/css/);
  });
});

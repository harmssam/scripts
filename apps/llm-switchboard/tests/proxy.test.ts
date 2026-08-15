import http from 'node:http';
import { AddressInfo } from 'node:net';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createHonoApp } from '../src/app.js';
import { createConfigStore } from '../src/config/store.js';
import { openEventsDb } from '../src/events/db.js';
import { createHealthTracker } from '../src/events/health.js';
import { createEventStore } from '../src/events/log.js';
import { resetRoundRobinCounters } from '../src/router/select.js';
import type { Config } from '../src/types.js';
import { verifyGatewayAuth } from '../src/proxy/auth.js';
import { chatCompletionsUrl } from '../src/proxy/upstream.js';

const GATEWAY_KEY = 'test-gateway-key';

interface MockServer {
  url: string;
  baseUrl: string;
  close: () => Promise<void>;
  hits: number;
}

function listen(server: http.Server): Promise<AddressInfo> {
  return new Promise((resolve, reject) => {
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      if (!addr || typeof addr === 'string') {
        reject(new Error('no address'));
        return;
      }
      resolve(addr);
    });
    server.on('error', reject);
  });
}

function closeServer(server: http.Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  });
}

/** Plan A: always 429. Plan B: 200 JSON chat completion. */
async function startFailoverMocks(): Promise<{ a: MockServer; b: MockServer }> {
  const aHits = { n: 0 };
  const bHits = { n: 0 };

  const serverA = http.createServer((req, res) => {
    aHits.n += 1;
    if (req.method === 'POST' && req.url?.includes('/chat/completions')) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'rate limited', type: 'rate_limit_error' } }));
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const serverB = http.createServer((req, res) => {
    bHits.n += 1;
    if (req.method === 'POST' && req.url?.includes('/chat/completions')) {
      let raw = '';
      req.on('data', (c) => {
        raw += c;
      });
      req.on('end', () => {
        const body = JSON.parse(raw || '{}') as { model?: string };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            id: 'chatcmpl-b',
            object: 'chat.completion',
            model: body.model ?? 'test-model',
            choices: [
              {
                index: 0,
                message: { role: 'assistant', content: 'hello from B' },
                finish_reason: 'stop',
              },
            ],
            usage: { prompt_tokens: 3, completion_tokens: 5, total_tokens: 8 },
          })
        );
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const addrA = await listen(serverA);
  const addrB = await listen(serverB);

  const make = (
    server: http.Server,
    addr: AddressInfo,
    hits: { n: number }
  ): MockServer => ({
    url: `http://127.0.0.1:${addr.port}`,
    baseUrl: `http://127.0.0.1:${addr.port}/v1`,
    close: () => closeServer(server),
    get hits() {
      return hits.n;
    },
  });

  return {
    a: make(serverA, addrA, aHits),
    b: make(serverB, addrB, bHits),
  };
}

/** Streaming SSE-like mock. */
async function startStreamMock(): Promise<MockServer & { chunks: string[] }> {
  const hits = { n: 0 };
  const chunks = [
    'data: {"id":"1","choices":[{"delta":{"content":"Hi"}}]}\n\n',
    'data: {"id":"1","choices":[{"delta":{"content":" there"}}]}\n\n',
    'data: [DONE]\n\n',
  ];

  const server = http.createServer((req, res) => {
    hits.n += 1;
    if (req.method === 'POST' && req.url?.includes('/chat/completions')) {
      req.resume();
      req.on('end', () => {
        res.writeHead(200, {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
        });
        for (const c of chunks) {
          res.write(c);
        }
        res.end();
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const addr = await listen(server);
  return {
    url: `http://127.0.0.1:${addr.port}`,
    baseUrl: `http://127.0.0.1:${addr.port}/v1`,
    close: () => closeServer(server),
    get hits() {
      return hits.n;
    },
    chunks,
  };
}

function configWithPlans(planABase: string, planBBase: string): Config {
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
        name: 'A',
        baseUrl: planABase,
        apiKey: 'key-a',
        providerType: 'openai-compat',
        enabled: true,
      },
      {
        id: 'plan-b',
        name: 'B',
        baseUrl: planBBase,
        apiKey: 'key-b',
        providerType: 'openai-compat',
        enabled: true,
      },
    ],
    groups: [
      {
        id: 'eq',
        name: 'equal',
        strategy: 'priority', // stable order: A then B
        planIds: ['plan-a', 'plan-b'],
        cooldownSeconds: 60,
      },
    ],
    routes: [
      {
        id: 'r1',
        model: 'test-model',
        targetType: 'group',
        targetId: 'eq',
      },
    ],
    defaultRoute: null,
  };
}

describe('proxy auth helpers', () => {
  it('verifyGatewayAuth accepts matching Bearer', () => {
    expect(verifyGatewayAuth(`Bearer ${GATEWAY_KEY}`, GATEWAY_KEY)).toBe(true);
    expect(verifyGatewayAuth('Bearer wrong', GATEWAY_KEY)).toBe(false);
    expect(verifyGatewayAuth(undefined, GATEWAY_KEY)).toBe(false);
  });

  it('chatCompletionsUrl strips trailing slash', () => {
    expect(chatCompletionsUrl('https://api.example.com/v1/')).toBe(
      'https://api.example.com/v1/chat/completions'
    );
  });
});

describe('OpenAI-compatible proxy', () => {
  let mocks: { a: MockServer; b: MockServer } | null = null;
  let streamMock: (MockServer & { chunks: string[] }) | null = null;
  let events: ReturnType<typeof createEventStore> | null = null;

  beforeEach(() => {
    resetRoundRobinCounters();
  });

  afterEach(async () => {
    if (mocks) {
      await mocks.a.close();
      await mocks.b.close();
      mocks = null;
    }
    if (streamMock) {
      await streamMock.close();
      streamMock = null;
    }
    events?.close();
    events = null;
  });

  function buildApp(config: Config) {
    const store = createConfigStore('/tmp/unused-proxy-test.yaml', config);
    events = createEventStore(openEventsDb(':memory:'));
    const health = createHealthTracker();
    const app = createHonoApp({ configStore: store, events, health });
    return { app, store, events, health };
  }

  it('GET /v1/models requires auth and lists routes', async () => {
    const { app } = buildApp(configWithPlans('http://127.0.0.1:1/v1', 'http://127.0.0.1:2/v1'));

    const unauth = await app.request('http://localhost/v1/models');
    expect(unauth.status).toBe(401);

    const res = await app.request('http://localhost/v1/models', {
      headers: { Authorization: `Bearer ${GATEWAY_KEY}` },
    });
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      object: string;
      data: Array<{ id: string; object: string; owned_by: string }>;
    };
    expect(json.object).toBe('list');
    expect(json.data).toEqual([
      { id: 'test-model', object: 'model', owned_by: 'switchboard' },
    ]);
  });

  it('fails over from 429 plan A to 200 plan B and logs failover', async () => {
    mocks = await startFailoverMocks();
    const { app, events: ev } = buildApp(configWithPlans(mocks.a.baseUrl, mocks.b.baseUrl));

    const res = await app.request('http://localhost/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GATEWAY_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'test-model',
        messages: [{ role: 'user', content: 'hi' }],
      }),
    });

    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      choices: Array<{ message: { content: string } }>;
      usage: { prompt_tokens: number; completion_tokens: number };
    };
    expect(json.choices[0]!.message.content).toBe('hello from B');
    expect(json.usage.prompt_tokens).toBe(3);

    expect(mocks.a.hits).toBe(1);
    expect(mocks.b.hits).toBe(1);

    const logged = ev.list(50);
    const types = logged.map((e) => e.type);
    expect(types).toContain('request_start');
    expect(types).toContain('upstream_attempt');
    expect(types).toContain('upstream_error');
    expect(types).toContain('failover');
    expect(types).toContain('upstream_success');
    expect(types).toContain('request_success');

    const failover = logged.find((e) => e.type === 'failover');
    expect(failover?.planId).toBe('plan-a');

    const success = logged.find((e) => e.type === 'request_success');
    expect(success?.planId).toBe('plan-b');
    expect(success?.promptTokens).toBe(3);
    expect(success?.completionTokens).toBe(5);
  });

  it('streams text/event-stream body through to client', async () => {
    streamMock = await startStreamMock();
    const config = configWithPlans(streamMock.baseUrl, streamMock.baseUrl);
    // single plan via priority group with one plan
    config.plans = [
      {
        id: 'plan-stream',
        name: 'Stream',
        baseUrl: streamMock.baseUrl,
        apiKey: 'k',
        providerType: 'openai-compat',
        enabled: true,
      },
    ];
    config.groups = [
      {
        id: 'eq',
        name: 'eq',
        strategy: 'priority',
        planIds: ['plan-stream'],
        cooldownSeconds: 60,
      },
    ];

    const { app } = buildApp(config);

    const res = await app.request('http://localhost/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GATEWAY_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'test-model',
        stream: true,
        messages: [{ role: 'user', content: 'hi' }],
      }),
    });

    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toMatch(/text\/event-stream/);
    const text = await res.text();
    expect(text).toContain('Hi');
    expect(text).toContain('there');
    expect(text).toContain('[DONE]');
    expect(streamMock.hits).toBe(1);
  });

  it('returns 404 when model has no candidates', async () => {
    const { app } = buildApp(configWithPlans('http://127.0.0.1:1/v1', 'http://127.0.0.1:2/v1'));
    const res = await app.request('http://localhost/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GATEWAY_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'unknown-model',
        messages: [{ role: 'user', content: 'hi' }],
      }),
    });
    expect(res.status).toBe(404);
  });

  it('rewrites body.model when route.upstreamModel is set', async () => {
    mocks = await startFailoverMocks();
    // only use plan B so we can inspect model
    const config = configWithPlans(mocks.a.baseUrl, mocks.b.baseUrl);
    config.routes = [
      {
        id: 'r1',
        model: 'test-model',
        targetType: 'plan',
        targetId: 'plan-b',
        upstreamModel: 'provider-real-model',
      },
    ];

    let seenModel: string | undefined;
    // replace B handler to capture model — restart B is complex; use custom server
    await mocks.b.close();
    const hits = { n: 0 };
    const serverB = http.createServer((req, res) => {
      hits.n += 1;
      let raw = '';
      req.on('data', (c) => {
        raw += c;
      });
      req.on('end', () => {
        const body = JSON.parse(raw || '{}') as { model?: string };
        seenModel = body.model;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            id: 'x',
            object: 'chat.completion',
            model: body.model,
            choices: [{ index: 0, message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
          })
        );
      });
    });
    const addr = await listen(serverB);
    mocks.b = {
      url: `http://127.0.0.1:${addr.port}`,
      baseUrl: `http://127.0.0.1:${addr.port}/v1`,
      close: () => closeServer(serverB),
      get hits() {
        return hits.n;
      },
    };
    config.plans[1]!.baseUrl = mocks.b.baseUrl;

    const { app } = buildApp(config);
    const res = await app.request('http://localhost/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GATEWAY_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'test-model',
        messages: [{ role: 'user', content: 'hi' }],
      }),
    });
    expect(res.status).toBe(200);
    expect(seenModel).toBe('provider-real-model');
  });
});

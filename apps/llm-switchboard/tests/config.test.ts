import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config/load.js';
import { saveConfig } from '../src/config/save.js';
import { createConfigStore } from '../src/config/store.js';
import {
  ConfigValidationError,
  emptyConfig,
  parseConfig,
  resolveConfigEnv,
  resolveEnvRefs,
} from '../src/config/schema.js';
import type { Config } from '../src/types.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const exampleYamlPath = join(__dirname, '..', 'config.example.yaml');

const tmpDirs: string[] = [];

afterEach(async () => {
  // leave tmp dirs; OS cleans tmp — no rmdir needed for tests
  tmpDirs.length = 0;
});

async function tempConfigPath(name = 'config.yaml'): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'llm-switchboard-'));
  tmpDirs.push(dir);
  return join(dir, name);
}

function sampleConfig(overrides?: Partial<Config>): Config {
  return {
    version: 1,
    settings: {
      gatewayKey: 'test-gateway-key',
      requestTimeoutMs: 120000,
      maxFailoverAttempts: 3,
      host: '127.0.0.1',
      port: 8787,
    },
    plans: [
      {
        id: 'p1',
        name: 'Plan One',
        baseUrl: 'https://api.example.com/v1',
        apiKey: '${MY_API_KEY}',
        providerType: 'openai-compat',
        enabled: true,
      },
    ],
    groups: [
      {
        id: 'g1',
        name: 'Group One',
        strategy: 'equal',
        planIds: ['p1'],
        cooldownSeconds: 120,
      },
    ],
    routes: [
      {
        id: 'r1',
        model: 'gpt-test',
        targetType: 'group',
        targetId: 'g1',
      },
    ],
    defaultRoute: { targetType: 'group', targetId: 'g1' },
    ...overrides,
  };
}

describe('resolveEnvRefs', () => {
  it('replaces ${VAR} from env map', () => {
    expect(resolveEnvRefs('Bearer ${TOKEN}', { TOKEN: 'abc' })).toBe('Bearer abc');
  });

  it('leaves unknown ${VAR} intact', () => {
    expect(resolveEnvRefs('${MISSING}', {})).toBe('${MISSING}');
  });

  it('replaces multiple refs in one string', () => {
    expect(resolveEnvRefs('${A}-${B}', { A: 'x', B: 'y' })).toBe('x-y');
  });
});

describe('parseConfig / validation', () => {
  it('rejects missing gateway key', () => {
    expect(() =>
      parseConfig({
        version: 1,
        settings: { gatewayKey: '' },
        plans: [],
        groups: [],
        routes: [],
      }),
    ).toThrow(ConfigValidationError);

    expect(() =>
      parseConfig({
        version: 1,
        settings: {},
        plans: [],
        groups: [],
        routes: [],
      }),
    ).toThrow(/gatewayKey/);
  });

  it('applies defaults for optional settings fields', () => {
    const cfg = parseConfig({
      version: 1,
      settings: { gatewayKey: 'k' },
      plans: [],
      groups: [],
      routes: [],
    });
    expect(cfg.settings.requestTimeoutMs).toBe(120000);
    expect(cfg.settings.maxFailoverAttempts).toBe(3);
    expect(cfg.settings.host).toBe('127.0.0.1');
    expect(cfg.settings.port).toBe(8787);
  });

  it('rejects unknown plan reference in group', () => {
    expect(() =>
      parseConfig({
        ...sampleConfig(),
        groups: [{ id: 'g1', name: 'G', strategy: 'equal', planIds: ['nope'], cooldownSeconds: 1 }],
      }),
    ).toThrow(/unknown planId/);
  });
});

describe('loadConfig', () => {
  it('loads example YAML and preserves ${ENV} templates', async () => {
    const cfg = await loadConfig(exampleYamlPath);
    expect(cfg.version).toBe(1);
    expect(cfg.settings.gatewayKey).toBe('${SWITCHBOARD_GATEWAY_KEY}');
    expect(cfg.plans.length).toBeGreaterThanOrEqual(1);
    expect(cfg.plans[0].apiKey).toMatch(/^\$\{.+\}$/);
    expect(cfg.groups[0].cooldownSeconds).toBe(120);
    expect(cfg.defaultRoute?.targetType).toBe('group');
  });

  it('throws when file missing', async () => {
    await expect(loadConfig('/tmp/does-not-exist-llm-switchboard-xyz.yaml')).rejects.toThrow(
      /not found/,
    );
  });
});

describe('saveConfig / round-trip', () => {
  it('round-trips save then load preserving env templates', async () => {
    const path = await tempConfigPath();
    const original = sampleConfig();
    await saveConfig(path, original);

    const text = await readFile(path, 'utf8');
    expect(text).toContain('${MY_API_KEY}');

    const loaded = await loadConfig(path);
    expect(loaded.settings.gatewayKey).toBe(original.settings.gatewayKey);
    expect(loaded.plans[0].apiKey).toBe('${MY_API_KEY}');
    expect(loaded.groups).toEqual(original.groups);
    expect(loaded.routes).toEqual(original.routes);
    expect(loaded.defaultRoute).toEqual(original.defaultRoute);
  });
});

describe('resolveConfigEnv', () => {
  it('resolves plan keys without mutating stored templates', () => {
    const stored = sampleConfig();
    const resolved = resolveConfigEnv(stored, { MY_API_KEY: 'secret-123' });
    expect(resolved.plans[0].apiKey).toBe('secret-123');
    expect(stored.plans[0].apiKey).toBe('${MY_API_KEY}');
  });
});

describe('ConfigStore', () => {
  it('reload, get, update with persist', async () => {
    const path = await tempConfigPath();
    await saveConfig(path, sampleConfig());

    const store = createConfigStore(path);
    const loaded = await store.reload();
    expect(loaded.plans[0].id).toBe('p1');

    await store.update((c) => ({
      ...c,
      plans: c.plans.map((p) => (p.id === 'p1' ? { ...p, name: 'Renamed' } : p)),
    }));

    expect(store.get().plans[0].name).toBe('Renamed');

    const reloaded = await store.reload();
    expect(reloaded.plans[0].name).toBe('Renamed');
  });

  it('update can skip persist', async () => {
    const path = await tempConfigPath();
    await saveConfig(path, sampleConfig());
    const store = createConfigStore(path);
    await store.reload();

    await store.update(
      (c) => ({
        ...c,
        settings: { ...c.settings, port: 9999 },
      }),
      { persist: false },
    );
    expect(store.get().settings.port).toBe(9999);

    const fromDisk = await loadConfig(path);
    expect(fromDisk.settings.port).toBe(8787);
  });
});

describe('emptyConfig', () => {
  it('builds a valid empty shell (except gateway key must be set before save use)', () => {
    const e = emptyConfig();
    expect(e.version).toBe(1);
    expect(e.plans).toEqual([]);
    // emptyConfig has empty gatewayKey — parse will reject until set
    expect(() => parseConfig(e)).toThrow(/gatewayKey/);
  });
});

describe('write minimal yaml fixture', () => {
  it('rejects yaml without gateway key', async () => {
    const path = await tempConfigPath();
    await writeFile(
      path,
      `version: 1
settings:
  requestTimeoutMs: 1000
plans: []
groups: []
routes: []
`,
      'utf8',
    );
    await expect(loadConfig(path)).rejects.toThrow(/gatewayKey/);
  });
});

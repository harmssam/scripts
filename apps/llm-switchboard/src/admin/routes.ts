import { Hono } from 'hono';
import { resolveEnvRefs } from '../config/schema.js';
import type { ConfigStore } from '../config/store.js';
import type { EventStore } from '../events/log.js';
import type { HealthTracker } from '../events/health.js';
import { gatewayAuthMiddleware } from '../proxy/auth.js';
import type { Config, EquivalenceGroup, ModelRoute, Plan, Settings } from '../types.js';

export interface AdminDeps {
  configStore: ConfigStore;
  events: EventStore;
  health: HealthTracker;
}

const MASK = '***';

/** Mask secrets for GET responses. */
export function maskConfig(config: Config): Record<string, unknown> {
  return {
    ...config,
    settings: {
      ...config.settings,
      gatewayKey: config.settings.gatewayKey ? MASK : '',
      gatewayKeySet: Boolean(config.settings.gatewayKey && config.settings.gatewayKey.trim() !== ''),
    },
    plans: config.plans.map((p) => ({
      ...p,
      apiKey: p.apiKey ? MASK : '',
      apiKeySet: Boolean(p.apiKey && p.apiKey.trim() !== ''),
    })),
  };
}

/** If client sent masked/empty key, keep the existing secret. */
function mergeApiKey(incoming: string | undefined, existing: string): string {
  if (incoming === undefined || incoming === null) return existing;
  if (incoming === MASK || incoming === '') return existing;
  return incoming;
}

function mergeGatewayKey(incoming: string | undefined, existing: string): string {
  return mergeApiKey(incoming, existing);
}

function asObject(body: unknown): Record<string, unknown> | null {
  if (typeof body === 'object' && body !== null && !Array.isArray(body)) {
    return body as Record<string, unknown>;
  }
  return null;
}

/**
 * Admin JSON API under `/admin/api/*`, same gateway auth as `/v1/*`.
 */
export function createAdminRoutes(deps: AdminDeps): Hono {
  const admin = new Hono();

  admin.use(
    '*',
    gatewayAuthMiddleware(() => deps.configStore.get().settings.gatewayKey)
  );

  // ── Meta ──────────────────────────────────────────────────────────
  admin.get('/meta', (c) => {
    return c.json({
      configPath: deps.configStore.path(),
      version: 1,
    });
  });

  // ── Overview ──────────────────────────────────────────────────────
  admin.get('/overview', (c) => {
    const config = deps.configStore.get();
    const stats = deps.events.stats();
    const healthSnap = deps.health.snapshot();
    const plans = config.plans.map((p) => {
      const h = healthSnap[p.id];
      return {
        id: p.id,
        name: p.name,
        enabled: p.enabled,
        status: h?.status ?? 'ok',
        failures: h?.failures ?? 0,
        cooldownUntil: h?.cooldownUntil,
      };
    });
    return c.json({
      stats,
      health: healthSnap,
      plans,
    });
  });

  // ── Full config ───────────────────────────────────────────────────
  admin.get('/config', (c) => {
    return c.json(maskConfig(deps.configStore.get()));
  });

  admin.put('/config', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      const current = deps.configStore.get();
      // Preserve secrets when client sends ***
      const plansRaw = Array.isArray(obj.plans) ? obj.plans : current.plans;
      const plans = (plansRaw as Plan[]).map((p) => {
        const existing = current.plans.find((x) => x.id === p.id);
        return {
          ...p,
          apiKey: mergeApiKey(
            typeof p.apiKey === 'string' ? p.apiKey : undefined,
            existing?.apiKey ?? ''
          ),
        };
      });
      const settingsIn = asObject(obj.settings) ?? {};
      const settings: Settings = {
        ...current.settings,
        ...(settingsIn as Partial<Settings>),
        gatewayKey: mergeGatewayKey(
          typeof settingsIn.gatewayKey === 'string' ? settingsIn.gatewayKey : undefined,
          current.settings.gatewayKey
        ),
      };

      const next: Config = {
        version: 1,
        settings,
        plans: plans as Plan[],
        groups: (Array.isArray(obj.groups) ? obj.groups : current.groups) as EquivalenceGroup[],
        routes: (Array.isArray(obj.routes) ? obj.routes : current.routes) as ModelRoute[],
        defaultRoute:
          obj.defaultRoute === undefined
            ? current.defaultRoute
            : (obj.defaultRoute as Config['defaultRoute']),
      };

      await deps.configStore.update(() => next);
      return c.json(maskConfig(deps.configStore.get()));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return c.json({ error: { message } }, 400);
    }
  });

  // ── Plans CRUD ────────────────────────────────────────────────────
  admin.get('/plans', (c) => {
    const config = deps.configStore.get();
    return c.json(
      config.plans.map((p) => ({
        ...p,
        apiKey: p.apiKey ? MASK : '',
        apiKeySet: Boolean(p.apiKey && p.apiKey.trim() !== ''),
      }))
    );
  });

  admin.post('/plans', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      const plan: Plan = {
        id: String(obj.id ?? ''),
        name: String(obj.name ?? ''),
        baseUrl: String(obj.baseUrl ?? ''),
        apiKey: typeof obj.apiKey === 'string' ? obj.apiKey : '',
        providerType: (obj.providerType as Plan['providerType']) ?? 'openai-compat',
        enabled: obj.enabled === undefined ? true : Boolean(obj.enabled),
      };
      await deps.configStore.update((cfg) => {
        if (cfg.plans.some((p) => p.id === plan.id)) {
          throw new Error(`plan id already exists: ${plan.id}`);
        }
        return { ...cfg, plans: [...cfg.plans, plan] };
      });
      return c.json(
        {
          ...plan,
          apiKey: plan.apiKey ? MASK : '',
          apiKeySet: Boolean(plan.apiKey),
        },
        201
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return c.json({ error: { message } }, 400);
    }
  });

  admin.put('/plans/:id', async (c) => {
    const id = c.req.param('id');
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      let updated: Plan | null = null;
      await deps.configStore.update((cfg) => {
        const idx = cfg.plans.findIndex((p) => p.id === id);
        if (idx < 0) throw new Error(`plan not found: ${id}`);
        const existing = cfg.plans[idx]!;
        const next: Plan = {
          id: existing.id,
          name: typeof obj.name === 'string' ? obj.name : existing.name,
          baseUrl: typeof obj.baseUrl === 'string' ? obj.baseUrl : existing.baseUrl,
          apiKey: mergeApiKey(
            typeof obj.apiKey === 'string' ? obj.apiKey : undefined,
            existing.apiKey
          ),
          providerType:
            (obj.providerType as Plan['providerType']) ?? existing.providerType,
          enabled:
            obj.enabled === undefined ? existing.enabled : Boolean(obj.enabled),
        };
        // Allow id change only if not colliding
        if (typeof obj.id === 'string' && obj.id !== existing.id) {
          if (cfg.plans.some((p) => p.id === obj.id)) {
            throw new Error(`plan id already exists: ${obj.id}`);
          }
          next.id = obj.id;
        }
        updated = next;
        const plans = [...cfg.plans];
        plans[idx] = next;
        // If id changed, rewrite group planIds references
        let groups = cfg.groups;
        if (next.id !== existing.id) {
          groups = cfg.groups.map((g) => ({
            ...g,
            planIds: g.planIds.map((pid) => (pid === existing.id ? next.id : pid)),
          }));
        }
        let routes = cfg.routes;
        if (next.id !== existing.id) {
          routes = cfg.routes.map((r) =>
            r.targetType === 'plan' && r.targetId === existing.id
              ? { ...r, targetId: next.id }
              : r
          );
        }
        let defaultRoute = cfg.defaultRoute;
        if (
          next.id !== existing.id &&
          defaultRoute?.targetType === 'plan' &&
          defaultRoute.targetId === existing.id
        ) {
          defaultRoute = { ...defaultRoute, targetId: next.id };
        }
        return { ...cfg, plans, groups, routes, defaultRoute };
      });
      return c.json({
        ...updated!,
        apiKey: updated!.apiKey ? MASK : '',
        apiKeySet: Boolean(updated!.apiKey),
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const status = message.includes('not found') ? 404 : 400;
      return c.json({ error: { message } }, status);
    }
  });

  admin.delete('/plans/:id', async (c) => {
    const id = c.req.param('id');
    try {
      await deps.configStore.update((cfg) => {
        if (!cfg.plans.some((p) => p.id === id)) {
          throw new Error(`plan not found: ${id}`);
        }
        // Block delete if still referenced
        for (const g of cfg.groups) {
          if (g.planIds.includes(id)) {
            throw new Error(`plan "${id}" is referenced by group "${g.id}"`);
          }
        }
        for (const r of cfg.routes) {
          if (r.targetType === 'plan' && r.targetId === id) {
            throw new Error(`plan "${id}" is referenced by route "${r.id}"`);
          }
        }
        if (cfg.defaultRoute?.targetType === 'plan' && cfg.defaultRoute.targetId === id) {
          throw new Error(`plan "${id}" is referenced by defaultRoute`);
        }
        return { ...cfg, plans: cfg.plans.filter((p) => p.id !== id) };
      });
      return c.json({ ok: true });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const status = message.includes('not found') ? 404 : 400;
      return c.json({ error: { message } }, status);
    }
  });

  // ── Groups CRUD ───────────────────────────────────────────────────
  admin.get('/groups', (c) => {
    return c.json(deps.configStore.get().groups);
  });

  admin.post('/groups', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      const group: EquivalenceGroup = {
        id: String(obj.id ?? ''),
        name: String(obj.name ?? ''),
        strategy: (obj.strategy as EquivalenceGroup['strategy']) ?? 'equal',
        planIds: Array.isArray(obj.planIds) ? (obj.planIds as string[]) : [],
        cooldownSeconds:
          typeof obj.cooldownSeconds === 'number' ? obj.cooldownSeconds : 120,
      };
      await deps.configStore.update((cfg) => {
        if (cfg.groups.some((g) => g.id === group.id)) {
          throw new Error(`group id already exists: ${group.id}`);
        }
        return { ...cfg, groups: [...cfg.groups, group] };
      });
      return c.json(group, 201);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return c.json({ error: { message } }, 400);
    }
  });

  admin.put('/groups/:id', async (c) => {
    const id = c.req.param('id');
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      let updated: EquivalenceGroup | null = null;
      await deps.configStore.update((cfg) => {
        const idx = cfg.groups.findIndex((g) => g.id === id);
        if (idx < 0) throw new Error(`group not found: ${id}`);
        const existing = cfg.groups[idx]!;
        const next: EquivalenceGroup = {
          id: existing.id,
          name: typeof obj.name === 'string' ? obj.name : existing.name,
          strategy:
            (obj.strategy as EquivalenceGroup['strategy']) ?? existing.strategy,
          planIds: Array.isArray(obj.planIds)
            ? (obj.planIds as string[])
            : existing.planIds,
          cooldownSeconds:
            typeof obj.cooldownSeconds === 'number'
              ? obj.cooldownSeconds
              : existing.cooldownSeconds,
        };
        if (typeof obj.id === 'string' && obj.id !== existing.id) {
          if (cfg.groups.some((g) => g.id === obj.id)) {
            throw new Error(`group id already exists: ${obj.id}`);
          }
          next.id = obj.id;
        }
        updated = next;
        const groups = [...cfg.groups];
        groups[idx] = next;
        let routes = cfg.routes;
        if (next.id !== existing.id) {
          routes = cfg.routes.map((r) =>
            r.targetType === 'group' && r.targetId === existing.id
              ? { ...r, targetId: next.id }
              : r
          );
        }
        let defaultRoute = cfg.defaultRoute;
        if (
          next.id !== existing.id &&
          defaultRoute?.targetType === 'group' &&
          defaultRoute.targetId === existing.id
        ) {
          defaultRoute = { ...defaultRoute, targetId: next.id };
        }
        return { ...cfg, groups, routes, defaultRoute };
      });
      return c.json(updated);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const status = message.includes('not found') ? 404 : 400;
      return c.json({ error: { message } }, status);
    }
  });

  admin.delete('/groups/:id', async (c) => {
    const id = c.req.param('id');
    try {
      await deps.configStore.update((cfg) => {
        if (!cfg.groups.some((g) => g.id === id)) {
          throw new Error(`group not found: ${id}`);
        }
        for (const r of cfg.routes) {
          if (r.targetType === 'group' && r.targetId === id) {
            throw new Error(`group "${id}" is referenced by route "${r.id}"`);
          }
        }
        if (cfg.defaultRoute?.targetType === 'group' && cfg.defaultRoute.targetId === id) {
          throw new Error(`group "${id}" is referenced by defaultRoute`);
        }
        return { ...cfg, groups: cfg.groups.filter((g) => g.id !== id) };
      });
      return c.json({ ok: true });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const status = message.includes('not found') ? 404 : 400;
      return c.json({ error: { message } }, status);
    }
  });

  // ── Routes CRUD ───────────────────────────────────────────────────
  admin.get('/routes', (c) => {
    return c.json(deps.configStore.get().routes);
  });

  admin.post('/routes', async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      const route: ModelRoute = {
        id: String(obj.id ?? ''),
        model: String(obj.model ?? ''),
        targetType: obj.targetType as ModelRoute['targetType'],
        targetId: String(obj.targetId ?? ''),
        ...(typeof obj.upstreamModel === 'string' && obj.upstreamModel.trim() !== ''
          ? { upstreamModel: obj.upstreamModel }
          : {}),
      };
      await deps.configStore.update((cfg) => {
        if (cfg.routes.some((r) => r.id === route.id)) {
          throw new Error(`route id already exists: ${route.id}`);
        }
        return { ...cfg, routes: [...cfg.routes, route] };
      });
      return c.json(route, 201);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return c.json({ error: { message } }, 400);
    }
  });

  admin.put('/routes/:id', async (c) => {
    const id = c.req.param('id');
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      let updated: ModelRoute | null = null;
      await deps.configStore.update((cfg) => {
        const idx = cfg.routes.findIndex((r) => r.id === id);
        if (idx < 0) throw new Error(`route not found: ${id}`);
        const existing = cfg.routes[idx]!;
        const next: ModelRoute = {
          id: existing.id,
          model: typeof obj.model === 'string' ? obj.model : existing.model,
          targetType:
            (obj.targetType as ModelRoute['targetType']) ?? existing.targetType,
          targetId: typeof obj.targetId === 'string' ? obj.targetId : existing.targetId,
        };
        if (typeof obj.upstreamModel === 'string') {
          if (obj.upstreamModel.trim() !== '') next.upstreamModel = obj.upstreamModel;
        } else if (existing.upstreamModel) {
          next.upstreamModel = existing.upstreamModel;
        }
        if (typeof obj.id === 'string' && obj.id !== existing.id) {
          if (cfg.routes.some((r) => r.id === obj.id)) {
            throw new Error(`route id already exists: ${obj.id}`);
          }
          next.id = obj.id;
        }
        updated = next;
        const routes = [...cfg.routes];
        routes[idx] = next;
        return { ...cfg, routes };
      });
      return c.json(updated);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const status = message.includes('not found') ? 404 : 400;
      return c.json({ error: { message } }, status);
    }
  });

  admin.delete('/routes/:id', async (c) => {
    const id = c.req.param('id');
    try {
      await deps.configStore.update((cfg) => {
        if (!cfg.routes.some((r) => r.id === id)) {
          throw new Error(`route not found: ${id}`);
        }
        return { ...cfg, routes: cfg.routes.filter((r) => r.id !== id) };
      });
      return c.json({ ok: true });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const status = message.includes('not found') ? 404 : 400;
      return c.json({ error: { message } }, status);
    }
  });

  // ── Events ────────────────────────────────────────────────────────
  admin.get('/events', (c) => {
    const limitRaw = c.req.query('limit');
    const limit = limitRaw ? Math.max(0, Math.floor(Number(limitRaw))) : 100;
    return c.json(deps.events.list(Number.isFinite(limit) ? limit : 100));
  });

  // ── Settings ──────────────────────────────────────────────────────
  async function handleSettings(c: import('hono').Context) {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: { message: 'Invalid JSON body' } }, 400);
    }
    const obj = asObject(body);
    if (!obj) return c.json({ error: { message: 'Body must be an object' } }, 400);

    try {
      await deps.configStore.update((cfg) => {
        const settings: Settings = {
          ...cfg.settings,
          gatewayKey: mergeGatewayKey(
            typeof obj.gatewayKey === 'string' ? obj.gatewayKey : undefined,
            cfg.settings.gatewayKey
          ),
          requestTimeoutMs:
            typeof obj.requestTimeoutMs === 'number'
              ? obj.requestTimeoutMs
              : cfg.settings.requestTimeoutMs,
          maxFailoverAttempts:
            typeof obj.maxFailoverAttempts === 'number'
              ? obj.maxFailoverAttempts
              : cfg.settings.maxFailoverAttempts,
          host:
            typeof obj.host === 'string' && obj.host.trim() !== ''
              ? obj.host
              : cfg.settings.host,
          port: typeof obj.port === 'number' ? obj.port : cfg.settings.port,
        };
        return { ...cfg, settings };
      });
      const s = deps.configStore.get().settings;
      return c.json({
        ...s,
        gatewayKey: s.gatewayKey ? MASK : '',
        gatewayKeySet: Boolean(s.gatewayKey),
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return c.json({ error: { message } }, 400);
    }
  }

  admin.post('/settings', handleSettings);
  admin.put('/settings', handleSettings);

  // ── Plan test ─────────────────────────────────────────────────────
  admin.post('/plans/:id/test', async (c) => {
    const id = c.req.param('id');
    const config = deps.configStore.get();
    const plan = config.plans.find((p) => p.id === id);
    if (!plan) {
      return c.json({ ok: false, status: null, error: `plan not found: ${id}` }, 404);
    }

    const base = resolveEnvRefs(plan.baseUrl).replace(/\/+$/, '');
    const url = `${base}/models`;
    const apiKey = resolveEnvRefs(plan.apiKey);
    const timeoutMs = Math.min(config.settings.requestTimeoutMs, 15_000);

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const res = await fetch(url, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
        signal: controller.signal,
      });
      const text = await res.text().catch(() => '');
      const snippet = text.slice(0, 200);
      return c.json({
        ok: res.ok,
        status: res.status,
        error: res.ok ? undefined : snippet || res.statusText,
        url,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return c.json({
        ok: false,
        status: null,
        error: message,
        url,
      });
    } finally {
      clearTimeout(timer);
    }
  });

  return admin;
}

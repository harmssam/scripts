import type {
  Config,
  DefaultRoute,
  EquivalenceGroup,
  GroupStrategy,
  ModelRoute,
  Plan,
  ProviderType,
  Settings,
} from '../types.js';
import { defaults } from '../env.js';

export type {
  Config,
  DefaultRoute,
  EquivalenceGroup,
  GroupStrategy,
  ModelRoute,
  Plan,
  ProviderType,
  Settings,
};

export class ConfigValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigValidationError';
  }
}

export function defaultSettings(partial?: Partial<Settings>): Settings {
  return {
    gatewayKey: partial?.gatewayKey ?? '',
    requestTimeoutMs: partial?.requestTimeoutMs ?? defaults.requestTimeoutMs,
    maxFailoverAttempts: partial?.maxFailoverAttempts ?? defaults.maxFailoverAttempts,
    host: partial?.host ?? defaults.host,
    port: partial?.port ?? defaults.port,
  };
}

export function emptyConfig(): Config {
  return {
    version: 1,
    settings: defaultSettings(),
    plans: [],
    groups: [],
    routes: [],
    defaultRoute: null,
  };
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function requireString(obj: Record<string, unknown>, key: string, ctx: string): string {
  const v = obj[key];
  if (typeof v !== 'string' || v.trim() === '') {
    throw new ConfigValidationError(`${ctx}: missing or empty string "${key}"`);
  }
  return v;
}

function optionalString(obj: Record<string, unknown>, key: string): string | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') {
    throw new ConfigValidationError(`expected string for "${key}"`);
  }
  return v;
}

function requireBoolean(obj: Record<string, unknown>, key: string, ctx: string, fallback?: boolean): boolean {
  const v = obj[key];
  if (v === undefined && fallback !== undefined) return fallback;
  if (typeof v !== 'boolean') {
    throw new ConfigValidationError(`${ctx}: "${key}" must be a boolean`);
  }
  return v;
}

function requireNumber(obj: Record<string, unknown>, key: string, ctx: string, fallback?: number): number {
  const v = obj[key];
  if (v === undefined && fallback !== undefined) return fallback;
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    throw new ConfigValidationError(`${ctx}: "${key}" must be a number`);
  }
  return v;
}

function parseProviderType(v: unknown, ctx: string): ProviderType {
  if (v === 'openai-compat') return v;
  throw new ConfigValidationError(`${ctx}: providerType must be "openai-compat"`);
}

function parseGroupStrategy(v: unknown, ctx: string): GroupStrategy {
  if (v === 'equal' || v === 'priority') return v;
  throw new ConfigValidationError(`${ctx}: strategy must be "equal" or "priority"`);
}

function parsePlan(raw: unknown, index: number): Plan {
  const ctx = `plans[${index}]`;
  if (!isObject(raw)) throw new ConfigValidationError(`${ctx}: must be an object`);
  return {
    id: requireString(raw, 'id', ctx),
    name: requireString(raw, 'name', ctx),
    baseUrl: requireString(raw, 'baseUrl', ctx),
    apiKey: typeof raw.apiKey === 'string' ? raw.apiKey : requireString(raw, 'apiKey', ctx),
    providerType: parseProviderType(raw.providerType ?? 'openai-compat', ctx),
    enabled: requireBoolean(raw, 'enabled', ctx, true),
  };
}

function parseGroup(raw: unknown, index: number): EquivalenceGroup {
  const ctx = `groups[${index}]`;
  if (!isObject(raw)) throw new ConfigValidationError(`${ctx}: must be an object`);
  const planIds = raw.planIds;
  if (!Array.isArray(planIds) || !planIds.every((p) => typeof p === 'string')) {
    throw new ConfigValidationError(`${ctx}: planIds must be an array of strings`);
  }
  return {
    id: requireString(raw, 'id', ctx),
    name: requireString(raw, 'name', ctx),
    strategy: parseGroupStrategy(raw.strategy ?? 'equal', ctx),
    planIds: planIds as string[],
    cooldownSeconds: requireNumber(raw, 'cooldownSeconds', ctx, defaults.cooldownSeconds),
  };
}

function parseRoute(raw: unknown, index: number): ModelRoute {
  const ctx = `routes[${index}]`;
  if (!isObject(raw)) throw new ConfigValidationError(`${ctx}: must be an object`);
  const targetType = raw.targetType;
  if (targetType !== 'group' && targetType !== 'plan') {
    throw new ConfigValidationError(`${ctx}: targetType must be "group" or "plan"`);
  }
  return {
    id: requireString(raw, 'id', ctx),
    model: requireString(raw, 'model', ctx),
    targetType,
    targetId: requireString(raw, 'targetId', ctx),
  };
}

function parseDefaultRoute(raw: unknown): DefaultRoute | null {
  if (raw === undefined || raw === null) return null;
  if (!isObject(raw)) throw new ConfigValidationError('defaultRoute: must be an object or null');
  const targetType = raw.targetType;
  if (targetType !== 'group' && targetType !== 'plan') {
    throw new ConfigValidationError('defaultRoute: targetType must be "group" or "plan"');
  }
  return {
    targetType,
    targetId: requireString(raw, 'targetId', 'defaultRoute'),
  };
}

function parseSettings(raw: unknown): Settings {
  if (!isObject(raw)) throw new ConfigValidationError('settings: must be an object');
  const gatewayKey = optionalString(raw, 'gatewayKey');
  if (gatewayKey === undefined || gatewayKey.trim() === '') {
    throw new ConfigValidationError('settings.gatewayKey is required');
  }
  return {
    gatewayKey,
    requestTimeoutMs: requireNumber(raw, 'requestTimeoutMs', 'settings', defaults.requestTimeoutMs),
    maxFailoverAttempts: requireNumber(
      raw,
      'maxFailoverAttempts',
      'settings',
      defaults.maxFailoverAttempts,
    ),
    host: typeof raw.host === 'string' && raw.host.trim() !== '' ? raw.host : defaults.host,
    port: requireNumber(raw, 'port', 'settings', defaults.port),
  };
}

/**
 * Validate and normalize unknown YAML/JSON into Config.
 * Preserves raw string values (including ${ENV} templates).
 */
export function parseConfig(raw: unknown): Config {
  if (!isObject(raw)) {
    throw new ConfigValidationError('config root must be an object');
  }

  const version = raw.version;
  if (version !== 1 && version !== '1') {
    throw new ConfigValidationError(`unsupported config version: ${String(version)} (expected 1)`);
  }

  const plansRaw = raw.plans ?? [];
  const groupsRaw = raw.groups ?? [];
  const routesRaw = raw.routes ?? [];

  if (!Array.isArray(plansRaw)) throw new ConfigValidationError('plans must be an array');
  if (!Array.isArray(groupsRaw)) throw new ConfigValidationError('groups must be an array');
  if (!Array.isArray(routesRaw)) throw new ConfigValidationError('routes must be an array');

  const plans = plansRaw.map(parsePlan);
  const groups = groupsRaw.map(parseGroup);
  const routes = routesRaw.map(parseRoute);
  const settings = parseSettings(raw.settings);
  const defaultRoute = parseDefaultRoute(raw.defaultRoute);

  // Referential integrity (soft: warn via throw for unknown ids)
  const planIds = new Set(plans.map((p) => p.id));
  const groupIds = new Set(groups.map((g) => g.id));

  for (const g of groups) {
    for (const pid of g.planIds) {
      if (!planIds.has(pid)) {
        throw new ConfigValidationError(`group "${g.id}" references unknown planId "${pid}"`);
      }
    }
  }

  for (const r of routes) {
    if (r.targetType === 'plan' && !planIds.has(r.targetId)) {
      throw new ConfigValidationError(`route "${r.id}" references unknown plan "${r.targetId}"`);
    }
    if (r.targetType === 'group' && !groupIds.has(r.targetId)) {
      throw new ConfigValidationError(`route "${r.id}" references unknown group "${r.targetId}"`);
    }
  }

  if (defaultRoute) {
    if (defaultRoute.targetType === 'plan' && !planIds.has(defaultRoute.targetId)) {
      throw new ConfigValidationError(`defaultRoute references unknown plan "${defaultRoute.targetId}"`);
    }
    if (defaultRoute.targetType === 'group' && !groupIds.has(defaultRoute.targetId)) {
      throw new ConfigValidationError(`defaultRoute references unknown group "${defaultRoute.targetId}"`);
    }
  }

  return {
    version: 1,
    settings,
    plans,
    groups,
    routes,
    defaultRoute,
  };
}

/** Replace ${VAR} placeholders in a string using process.env (or provided env map). */
export function resolveEnvRefs(value: string, env: NodeJS.ProcessEnv = process.env): string {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (match, name: string) => {
    const v = env[name];
    if (v === undefined) return match; // leave unresolved if missing
    return v;
  });
}

/** Deep-resolve all string fields that may contain ${ENV} for upstream use. */
export function resolveConfigEnv(config: Config, env: NodeJS.ProcessEnv = process.env): Config {
  return {
    ...config,
    settings: {
      ...config.settings,
      gatewayKey: resolveEnvRefs(config.settings.gatewayKey, env),
      host: resolveEnvRefs(config.settings.host, env),
    },
    plans: config.plans.map((p) => ({
      ...p,
      baseUrl: resolveEnvRefs(p.baseUrl, env),
      apiKey: resolveEnvRefs(p.apiKey, env),
      name: resolveEnvRefs(p.name, env),
    })),
  };
}

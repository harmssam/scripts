export type ProviderType = 'openai-compat';

export interface Plan {
  id: string;
  name: string;
  baseUrl: string; // e.g. https://api.openai.com/v1
  apiKey: string; // may be ${ENV}
  providerType: ProviderType;
  enabled: boolean;
}

export type GroupStrategy = 'equal' | 'priority';

export interface EquivalenceGroup {
  id: string;
  name: string;
  strategy: GroupStrategy;
  planIds: string[]; // order = priority when strategy=priority
  cooldownSeconds: number; // default 120
}

export interface ModelRoute {
  id: string;
  model: string; // virtual model clients request
  targetType: 'group' | 'plan';
  targetId: string;
  /** If set, rewrite body.model when calling upstream (virtual id stays for clients). */
  upstreamModel?: string;
}

export interface Settings {
  gatewayKey: string;
  requestTimeoutMs: number; // default 120000
  maxFailoverAttempts: number; // default 3
  host: string; // default 127.0.0.1
  port: number; // default 8787
}

export interface DefaultRoute {
  targetType: 'group' | 'plan';
  targetId: string;
}

export interface Config {
  version: 1;
  settings: Settings;
  plans: Plan[];
  groups: EquivalenceGroup[];
  routes: ModelRoute[];
  defaultRoute?: DefaultRoute | null;
}

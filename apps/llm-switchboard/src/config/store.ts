import type { Config } from '../types.js';
import { loadConfig } from './load.js';
import { saveConfig } from './save.js';
import { parseConfig } from './schema.js';

export interface ConfigStore {
  get(): Config;
  /** Mutate config via updater; re-validates and optionally persists. */
  update(fn: (current: Config) => Config, options?: { persist?: boolean }): Promise<Config>;
  reload(): Promise<Config>;
  path(): string;
}

/**
 * In-memory config store. Raw values (including ${ENV}) are kept for save;
 * resolve with resolveEnvRefs when calling upstream.
 */
export function createConfigStore(configFilePath: string, initial?: Config): ConfigStore {
  let current: Config | null = initial ? parseConfig(initial) : null;

  return {
    get(): Config {
      if (!current) {
        throw new Error('ConfigStore not loaded; call reload() first');
      }
      // Return a deep-ish clone so callers cannot mutate store state by accident
      return structuredClone(current);
    },

    async update(fn, options = {}): Promise<Config> {
      if (!current) {
        throw new Error('ConfigStore not loaded; call reload() first');
      }
      const next = parseConfig(fn(structuredClone(current)));
      current = next;
      if (options.persist !== false) {
        await saveConfig(configFilePath, current);
      }
      return structuredClone(current);
    },

    async reload(): Promise<Config> {
      current = await loadConfig(configFilePath);
      return structuredClone(current);
    },

    path(): string {
      return configFilePath;
    },
  };
}

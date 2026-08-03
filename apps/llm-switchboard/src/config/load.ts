import { readFile } from 'node:fs/promises';
import { parse as parseYaml } from 'yaml';
import type { Config } from '../types.js';
import { ConfigValidationError, parseConfig } from './schema.js';

/**
 * Load and validate config from a YAML file.
 * Keeps raw string values (including ${ENV} templates) for later save.
 * Call resolveEnvRefs / resolveConfigEnv when sending secrets upstream.
 */
export async function loadConfig(path: string): Promise<Config> {
  let text: string;
  try {
    text = await readFile(path, 'utf8');
  } catch (err) {
    const e = err as NodeJS.ErrnoException;
    if (e.code === 'ENOENT') {
      throw new ConfigValidationError(`config file not found: ${path}`);
    }
    throw err;
  }

  let raw: unknown;
  try {
    raw = parseYaml(text);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new ConfigValidationError(`invalid YAML in ${path}: ${msg}`);
  }

  if (raw === null || raw === undefined) {
    throw new ConfigValidationError(`config file is empty: ${path}`);
  }

  return parseConfig(raw);
}

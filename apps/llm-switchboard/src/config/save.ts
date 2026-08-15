import { mkdir, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { stringify as stringifyYaml } from 'yaml';
import type { Config } from '../types.js';
import { parseConfig } from './schema.js';

/**
 * Atomically write config YAML to path.
 * Writes the in-memory config as-is (preserves ${ENV} templates if present).
 */
export async function saveConfig(path: string, config: Config): Promise<void> {
  // Re-validate before write
  const validated = parseConfig(config);

  const dir = dirname(path);
  await mkdir(dir, { recursive: true });

  const yaml = stringifyYaml(validated, {
    lineWidth: 0,
    defaultStringType: 'PLAIN',
    defaultKeyType: 'PLAIN',
  });

  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmp, yaml, 'utf8');
  await rename(tmp, path);
}

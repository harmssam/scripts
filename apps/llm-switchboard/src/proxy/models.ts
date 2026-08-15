import type { Context } from 'hono';
import type { ConfigStore } from '../config/store.js';

/**
 * GET /v1/models — list configured routes as OpenAI model objects.
 * `id` is the virtual route model name.
 */
export function createModelsHandler(configStore: ConfigStore) {
  return async (c: Context) => {
    const config = configStore.get();
    const data = config.routes.map((route) => ({
      id: route.model,
      object: 'model' as const,
      owned_by: 'switchboard',
    }));
    return c.json({
      object: 'list',
      data,
    });
  };
}

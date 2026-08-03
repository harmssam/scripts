import { Hono } from 'hono';
import type { ConfigStore } from './config/store.js';
import type { EventStore } from './events/log.js';
import type { HealthTracker } from './events/health.js';
import { gatewayAuthMiddleware } from './proxy/auth.js';
import { createChatHandler } from './proxy/chat.js';
import { createModelsHandler } from './proxy/models.js';

export interface AppDeps {
  configStore: ConfigStore;
  events: EventStore;
  health: HealthTracker;
}

/**
 * Build the Hono app (no listen). Used by index.ts and tests via `app.request`.
 */
export function createHonoApp(deps: AppDeps): Hono {
  const app = new Hono();

  app.get('/healthz', (c) => c.json({ ok: true }));

  const v1 = new Hono();
  v1.use(
    '*',
    gatewayAuthMiddleware(() => deps.configStore.get().settings.gatewayKey)
  );
  v1.get('/models', createModelsHandler(deps.configStore));
  v1.post('/chat/completions', createChatHandler(deps));

  app.route('/v1', v1);

  return app;
}

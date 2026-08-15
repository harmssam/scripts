import { readFile } from 'node:fs/promises';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Hono } from 'hono';
import { createAdminRoutes } from './admin/routes.js';
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

const DASHBOARD_DIR = join(dirname(fileURLToPath(import.meta.url)), 'dashboard');

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.json': 'application/json',
};

async function serveDashboardFile(name: string): Promise<Response> {
  const safe = name.replace(/\\/g, '/').replace(/^\/+/, '');
  if (safe.includes('..') || safe.includes('/')) {
    return new Response('Not found', { status: 404 });
  }
  const filePath = join(DASHBOARD_DIR, safe || 'index.html');
  try {
    const data = await readFile(filePath);
    const ext = extname(filePath).toLowerCase();
    return new Response(data, {
      status: 200,
      headers: {
        'Content-Type': MIME[ext] ?? 'application/octet-stream',
        'Cache-Control': 'no-cache',
      },
    });
  } catch {
    return new Response('Not found', { status: 404 });
  }
}

/**
 * Build the Hono app (no listen). Used by index.ts and tests via `app.request`.
 */
export function createHonoApp(deps: AppDeps): Hono {
  const app = new Hono();

  app.get('/healthz', (c) => c.json({ ok: true }));

  // Admin API (auth inside routes)
  app.route('/admin/api', createAdminRoutes(deps));

  // OpenAI-compatible API
  const v1 = new Hono();
  v1.use(
    '*',
    gatewayAuthMiddleware(() => deps.configStore.get().settings.gatewayKey)
  );
  v1.get('/models', createModelsHandler(deps.configStore));
  v1.post('/chat/completions', createChatHandler(deps));
  app.route('/v1', v1);

  // Static dashboard (offline-friendly, no CDN)
  app.get('/', async () => serveDashboardFile('index.html'));
  app.get('/index.html', async () => serveDashboardFile('index.html'));
  app.get('/app.js', async () => serveDashboardFile('app.js'));
  app.get('/styles.css', async () => serveDashboardFile('styles.css'));

  return app;
}

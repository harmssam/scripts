/**
 * LLM Switchboard entrypoint — OpenAI-compatible proxy with multi-plan failover.
 */
import { serve } from '@hono/node-server';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createHonoApp } from './app.js';
import { createConfigStore } from './config/store.js';
import { configPath, dataPath, port } from './env.js';
import { openEventsDb } from './events/db.js';
import { createHealthTracker } from './events/health.js';
import { createEventStore } from './events/log.js';

async function main(): Promise<void> {
  const cfgPath = configPath();
  const store = createConfigStore(cfgPath);
  await store.reload();

  mkdirSync(dataPath(), { recursive: true });
  const events = createEventStore(openEventsDb(join(dataPath(), 'events.db')));
  const health = createHealthTracker();

  const app = createHonoApp({
    configStore: store,
    events,
    health,
  });

  const config = store.get();
  // Env overrides take precedence over config settings
  const bindHost = process.env.SWITCHBOARD_HOST ?? config.settings.host;
  const bindPort =
    process.env.SWITCHBOARD_PORT !== undefined && process.env.SWITCHBOARD_PORT !== ''
      ? port()
      : config.settings.port;

  serve(
    {
      fetch: app.fetch,
      hostname: bindHost,
      port: bindPort,
    },
    (info) => {
      console.log(`llm-switchboard listening on http://${info.address}:${info.port}`);
      console.log(`  config: ${cfgPath}`);
      console.log(`  data:   ${dataPath()}`);
    }
  );
}

main().catch((err) => {
  console.error('llm-switchboard failed to start:', err);
  process.exit(1);
});

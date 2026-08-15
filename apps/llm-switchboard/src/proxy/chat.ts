import type { Context } from 'hono';
import type { ConfigStore } from '../config/store.js';
import { defaults } from '../env.js';
import type { EventStore } from '../events/log.js';
import type { HealthTracker } from '../events/health.js';
import { isRetryable } from '../router/failover.js';
import { resolvePlanCandidates } from '../router/select.js';
import type { Config } from '../types.js';
import { callChatCompletions, readBodyText } from './upstream.js';

export interface ChatDeps {
  configStore: ConfigStore;
  events: EventStore;
  health: HealthTracker;
}

function cooldownForPlan(config: Config, planId: string): number {
  const group = config.groups.find((g) => g.planIds.includes(planId));
  return group?.cooldownSeconds ?? defaults.cooldownSeconds;
}

function errMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}

function parseUsage(json: unknown): {
  promptTokens?: number | null;
  completionTokens?: number | null;
} {
  if (typeof json !== 'object' || json === null) return {};
  const usage = (json as { usage?: unknown }).usage;
  if (typeof usage !== 'object' || usage === null) return {};
  const u = usage as { prompt_tokens?: unknown; completion_tokens?: unknown };
  const out: { promptTokens?: number | null; completionTokens?: number | null } = {};
  if (typeof u.prompt_tokens === 'number') out.promptTokens = u.prompt_tokens;
  if (typeof u.completion_tokens === 'number') out.completionTokens = u.completion_tokens;
  return out;
}

/**
 * POST /v1/chat/completions — route to plan candidates with failover.
 * No mid-stream failover: once a successful upstream response is being streamed, stick with it.
 */
export function createChatHandler(deps: ChatDeps) {
  return async (c: Context) => {
    let body: Record<string, unknown>;
    try {
      body = (await c.req.json()) as Record<string, unknown>;
    } catch {
      return c.json(
        {
          error: {
            message: 'Invalid JSON body',
            type: 'invalid_request_error',
          },
        },
        400
      );
    }

    const model = body.model;
    if (typeof model !== 'string' || model.trim() === '') {
      return c.json(
        {
          error: {
            message: 'Missing required field: model',
            type: 'invalid_request_error',
            code: 'invalid_request_error',
          },
        },
        400
      );
    }

    const virtualModel = model;
    const stream = body.stream === true;
    const requestId = crypto.randomUUID();
    const config = deps.configStore.get();
    const settings = config.settings;

    deps.events.append({
      type: 'request_start',
      requestId,
      virtualModel,
      message: stream ? 'stream=true' : 'stream=false',
    });

    const candidates = resolvePlanCandidates(config, virtualModel, deps.health);
    if (candidates.length === 0) {
      deps.events.append({
        type: 'request_error',
        requestId,
        virtualModel,
        statusCode: 404,
        message: `No plan candidates for model "${virtualModel}"`,
      });
      return c.json(
        {
          error: {
            message: `No route or available plans for model: ${virtualModel}`,
            type: 'invalid_request_error',
            code: 'model_not_found',
          },
        },
        404
      );
    }

    const maxAttempts = Math.min(settings.maxFailoverAttempts, candidates.length);
    const route = config.routes.find((r) => r.model === virtualModel);
    let streamStarted = false;

    for (let i = 0; i < maxAttempts; i++) {
      const { plan, reason } = candidates[i]!;
      const started = Date.now();

      deps.events.append({
        type: 'upstream_attempt',
        requestId,
        virtualModel,
        planId: plan.id,
        message: reason,
      });

      // Clone body; optional route.upstreamModel rewrite
      const upstreamBody: Record<string, unknown> = { ...body };
      if (route?.upstreamModel) {
        upstreamBody.model = route.upstreamModel;
      }

      const upstream = await callChatCompletions(
        plan,
        upstreamBody,
        settings.requestTimeoutMs
      );
      const latencyMs = Date.now() - started;
      const moreCandidates = i + 1 < maxAttempts;

      if (upstream.status === null) {
        // Network / timeout
        const retry = isRetryable(null, upstream.error) && moreCandidates && !streamStarted;
        deps.events.append({
          type: 'upstream_error',
          requestId,
          virtualModel,
          planId: plan.id,
          latencyMs,
          message: errMessage(upstream.error ?? 'network error'),
        });
        deps.health.recordFailure(plan.id, cooldownForPlan(config, plan.id));
        if (retry) {
          deps.events.append({
            type: 'failover',
            requestId,
            virtualModel,
            planId: plan.id,
            message: `failover after network error → next candidate`,
          });
          continue;
        }
        deps.events.append({
          type: 'request_error',
          requestId,
          virtualModel,
          planId: plan.id,
          latencyMs,
          message: errMessage(upstream.error ?? 'upstream unreachable'),
        });
        return c.json(
          {
            error: {
              message: 'Upstream request failed',
              type: 'api_error',
              code: 'upstream_error',
            },
          },
          502
        );
      }

      const ok = upstream.status >= 200 && upstream.status < 300;

      if (!ok) {
        const text = await readBodyText(upstream.body);
        const retry =
          isRetryable(upstream.status, upstream.error) && moreCandidates && !streamStarted;

        deps.events.append({
          type: 'upstream_error',
          requestId,
          virtualModel,
          planId: plan.id,
          statusCode: upstream.status,
          latencyMs,
          message: text.slice(0, 500) || `HTTP ${upstream.status}`,
        });
        deps.health.recordFailure(
          plan.id,
          cooldownForPlan(config, plan.id),
          upstream.status
        );

        if (retry) {
          deps.events.append({
            type: 'failover',
            requestId,
            virtualModel,
            planId: plan.id,
            statusCode: upstream.status,
            message: `failover after HTTP ${upstream.status} → next candidate`,
          });
          continue;
        }

        deps.events.append({
          type: 'request_error',
          requestId,
          virtualModel,
          planId: plan.id,
          statusCode: upstream.status,
          latencyMs,
          message: `upstream returned ${upstream.status}`,
        });

        const contentType = upstream.headers.get('content-type') ?? 'application/json';
        return new Response(text, {
          status: upstream.status,
          headers: { 'Content-Type': contentType },
        });
      }

      // Success
      deps.health.recordSuccess(plan.id);
      deps.events.append({
        type: 'upstream_success',
        requestId,
        virtualModel,
        planId: plan.id,
        statusCode: upstream.status,
        latencyMs,
      });

      if (stream) {
        streamStarted = true;
        deps.events.append({
          type: 'request_success',
          requestId,
          virtualModel,
          planId: plan.id,
          statusCode: upstream.status,
          latencyMs,
          message: 'stream started',
        });
        const contentType =
          upstream.headers.get('content-type') ?? 'text/event-stream';
        return new Response(upstream.body, {
          status: upstream.status,
          headers: {
            'Content-Type': contentType,
            // Avoid accidental buffering proxies
            'Cache-Control': 'no-cache',
          },
        });
      }

      // Non-stream JSON
      const text = await readBodyText(upstream.body);
      let promptTokens: number | null | undefined;
      let completionTokens: number | null | undefined;
      try {
        const json = JSON.parse(text) as unknown;
        const usage = parseUsage(json);
        promptTokens = usage.promptTokens;
        completionTokens = usage.completionTokens;
      } catch {
        /* leave usage unset */
      }

      deps.events.append({
        type: 'request_success',
        requestId,
        virtualModel,
        planId: plan.id,
        statusCode: upstream.status,
        latencyMs,
        promptTokens,
        completionTokens,
      });

      const contentType = upstream.headers.get('content-type') ?? 'application/json';
      return new Response(text, {
        status: upstream.status,
        headers: { 'Content-Type': contentType },
      });
    }

    // Should not reach (loop always returns), but defensive
    deps.events.append({
      type: 'request_error',
      requestId,
      virtualModel,
      message: 'exhausted candidates',
    });
    return c.json(
      {
        error: {
          message: 'All upstream plans failed',
          type: 'api_error',
        },
      },
      502
    );
  };
}


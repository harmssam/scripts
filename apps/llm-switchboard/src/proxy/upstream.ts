import { resolveEnvRefs } from '../config/schema.js';
import type { Plan } from '../types.js';

export interface UpstreamResponse {
  /** HTTP status, or `null` on network/timeout (no response). */
  status: number | null;
  headers: Headers;
  body: ReadableStream<Uint8Array> | null;
  /** Error when status is null (fetch failed / aborted). */
  error?: unknown;
}

/** Normalize base URL and append `/chat/completions`. */
export function chatCompletionsUrl(baseUrl: string): string {
  const resolved = resolveEnvRefs(baseUrl).replace(/\/+$/, '');
  return `${resolved}/chat/completions`;
}

/**
 * POST to `${plan.baseUrl}/chat/completions` with Bearer plan apiKey.
 * Uses AbortSignal timeout from `timeoutMs`.
 */
export async function callChatCompletions(
  plan: Plan,
  body: unknown,
  timeoutMs: number
): Promise<UpstreamResponse> {
  const url = chatCompletionsUrl(plan.baseUrl);
  const apiKey = resolveEnvRefs(plan.apiKey);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, timeoutMs));

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    return {
      status: res.status,
      headers: res.headers,
      body: res.body,
    };
  } catch (err) {
    return {
      status: null,
      headers: new Headers(),
      body: null,
      error: err,
    };
  } finally {
    clearTimeout(timer);
  }
}

/** Read upstream body fully as text (consumes stream). */
export async function readBodyText(body: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!body) return '';
  return new Response(body).text();
}

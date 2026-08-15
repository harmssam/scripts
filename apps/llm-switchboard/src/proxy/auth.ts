import type { Context, Next } from 'hono';
import { resolveEnvRefs } from '../config/schema.js';

/**
 * Verify gateway key from either:
 * - `Authorization: Bearer <key>`
 * - `X-Switchboard-Key: <key>`
 */
export function verifyGatewayAuth(
  authorizationHeader: string | undefined,
  gatewayKeyRaw: string,
  switchboardKeyHeader?: string | undefined
): boolean {
  const expected = resolveEnvRefs(gatewayKeyRaw);
  if (!expected) return false;

  if (switchboardKeyHeader !== undefined && switchboardKeyHeader.trim() !== '') {
    if (switchboardKeyHeader.trim() === expected) return true;
  }

  if (!authorizationHeader || !authorizationHeader.startsWith('Bearer ')) {
    return false;
  }
  const token = authorizationHeader.slice('Bearer '.length).trim();
  if (token === '') return false;
  return token === expected;
}

/** Hono middleware factory: 401 unless Bearer or X-Switchboard-Key matches. */
export function gatewayAuthMiddleware(getGatewayKey: () => string) {
  return async (c: Context, next: Next) => {
    const ok = verifyGatewayAuth(
      c.req.header('Authorization'),
      getGatewayKey(),
      c.req.header('X-Switchboard-Key')
    );
    if (!ok) {
      return c.json(
        {
          error: {
            message: 'Invalid or missing Authorization Bearer token or X-Switchboard-Key',
            type: 'invalid_request_error',
            code: 'invalid_api_key',
          },
        },
        401
      );
    }
    await next();
  };
}

import type { Context, Next } from 'hono';
import { resolveEnvRefs } from '../config/schema.js';

/**
 * Verify `Authorization: Bearer <gateway_key>` against the resolved gateway key from config.
 */
export function verifyGatewayAuth(
  authorizationHeader: string | undefined,
  gatewayKeyRaw: string
): boolean {
  if (!authorizationHeader || !authorizationHeader.startsWith('Bearer ')) {
    return false;
  }
  const token = authorizationHeader.slice('Bearer '.length).trim();
  if (token === '') return false;
  const expected = resolveEnvRefs(gatewayKeyRaw);
  return token === expected;
}

/** Hono middleware factory: 401 unless Bearer matches resolved gateway key. */
export function gatewayAuthMiddleware(getGatewayKey: () => string) {
  return async (c: Context, next: Next) => {
    const ok = verifyGatewayAuth(c.req.header('Authorization'), getGatewayKey());
    if (!ok) {
      return c.json(
        {
          error: {
            message: 'Invalid or missing Authorization Bearer token',
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

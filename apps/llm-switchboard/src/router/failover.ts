/**
 * Classify upstream failures as retryable (try next plan) or terminal.
 *
 * Retryable: 429, 502, 503, 504, 401, 403, null status (network), timeouts.
 * Not retryable: 400 and other 4xx except 401/403/429.
 */

const RETRYABLE_STATUS = new Set([401, 403, 429, 502, 503, 504]);

function isTimeoutError(err: unknown): boolean {
  if (err == null) return false;
  if (typeof err === 'object') {
    const e = err as { name?: string; code?: string; message?: string; cause?: unknown };
    if (e.name === 'TimeoutError' || e.name === 'AbortError') return true;
    if (e.code === 'ETIMEDOUT' || e.code === 'ABORT_ERR') return true;
    if (typeof e.message === 'string' && /timeout/i.test(e.message)) return true;
    if (e.cause !== undefined) return isTimeoutError(e.cause);
  }
  if (typeof err === 'string' && /timeout/i.test(err)) return true;
  return false;
}

/**
 * @param status HTTP status from upstream, or `null` when no response (network/DNS/connect).
 * @param err optional error (used to detect timeouts when status is null).
 */
export function isRetryable(status: number | null, err?: unknown): boolean {
  if (status === null) {
    // Network failure or timeout — always try next plan
    return true;
  }
  if (RETRYABLE_STATUS.has(status)) {
    return true;
  }
  // Explicit timeout even if a status was somehow set (defensive)
  if (isTimeoutError(err)) {
    return true;
  }
  return false;
}

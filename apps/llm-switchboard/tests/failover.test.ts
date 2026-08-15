import { describe, expect, it } from 'vitest';
import { isRetryable } from '../src/router/failover.js';

describe('isRetryable', () => {
  it('treats null status as network failure (retryable)', () => {
    expect(isRetryable(null)).toBe(true);
    expect(isRetryable(null, new Error('ECONNREFUSED'))).toBe(true);
  });

  it('retries on 429, 502, 503, 504', () => {
    for (const s of [429, 502, 503, 504]) {
      expect(isRetryable(s)).toBe(true);
    }
  });

  it('retries next plan on 401 and 403', () => {
    expect(isRetryable(401)).toBe(true);
    expect(isRetryable(403)).toBe(true);
  });

  it('does not retry on 400 and other client 4xx', () => {
    for (const s of [400, 404, 405, 409, 413, 422]) {
      expect(isRetryable(s)).toBe(false);
    }
  });

  it('does not retry on other 5xx except 502/503/504', () => {
    expect(isRetryable(500)).toBe(false);
    expect(isRetryable(501)).toBe(false);
  });

  it('retries on timeout errors (null status)', () => {
    expect(isRetryable(null, Object.assign(new Error('The operation was aborted due to timeout'), { name: 'TimeoutError' }))).toBe(
      true
    );
    expect(isRetryable(null, Object.assign(new Error('aborted'), { name: 'AbortError' }))).toBe(true);
    expect(isRetryable(null, Object.assign(new Error('connect timed out'), { code: 'ETIMEDOUT' }))).toBe(
      true
    );
    expect(isRetryable(null, new Error('request timeout after 120000ms'))).toBe(true);
  });

  it('does not retry successful or unknown statuses', () => {
    expect(isRetryable(200)).toBe(false);
    expect(isRetryable(201)).toBe(false);
    expect(isRetryable(301)).toBe(false);
  });
});

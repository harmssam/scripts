/** Consecutive failures before entering cooldown (unless 429 forces immediate). */
export const DEFAULT_FAILURE_THRESHOLD = 2;

export interface HealthTracker {
  /** Optional statusCode: 429 enters cooldown immediately. */
  recordFailure(planId: string, cooldownSeconds: number, statusCode?: number): void;
  recordSuccess(planId: string): void;
  isAvailable(planId: string): boolean;
  status(planId: string): 'ok' | 'degraded' | 'cooldown';
  snapshot(): Record<string, { status: string; failures: number; cooldownUntil?: number }>;
}

interface PlanHealth {
  failures: number;
  cooldownUntil?: number;
}

export interface HealthTrackerOptions {
  /** Clock for tests; defaults to Date.now. */
  now?: () => number;
  /** Consecutive failures that trigger cooldown. Default 2. */
  failureThreshold?: number;
}

export interface HealthTrackerHandle extends HealthTracker {
  /**
   * Record a failure; if `statusCode` is 429, enter cooldown immediately
   * regardless of consecutive failure count.
   * (Optional third arg extends the brief interface for rate-limit handling.)
   */
  recordFailure(planId: string, cooldownSeconds: number, statusCode?: number): void;
}

/**
 * In-memory plan health / cooldown tracker.
 *
 * Cooldown starts when:
 * - consecutive failures reach `failureThreshold` (default 2), or
 * - any failure with HTTP 429 is recorded.
 *
 * cooldownUntil = now + cooldownSeconds * 1000
 */
export function createHealthTracker(options: HealthTrackerOptions = {}): HealthTrackerHandle {
  const now = options.now ?? (() => Date.now());
  const threshold = options.failureThreshold ?? DEFAULT_FAILURE_THRESHOLD;
  const plans = new Map<string, PlanHealth>();

  function ensure(planId: string): PlanHealth {
    let p = plans.get(planId);
    if (!p) {
      p = { failures: 0 };
      plans.set(planId, p);
    }
    return p;
  }

  function clearExpiredCooldown(p: PlanHealth): void {
    if (p.cooldownUntil !== undefined && p.cooldownUntil <= now()) {
      delete p.cooldownUntil;
    }
  }

  function computeStatus(p: PlanHealth): 'ok' | 'degraded' | 'cooldown' {
    clearExpiredCooldown(p);
    if (p.cooldownUntil !== undefined && p.cooldownUntil > now()) {
      return 'cooldown';
    }
    if (p.failures > 0) return 'degraded';
    return 'ok';
  }

  return {
    recordFailure(planId, cooldownSeconds, statusCode?) {
      const p = ensure(planId);
      clearExpiredCooldown(p);
      p.failures += 1;
      const rateLimited = statusCode === 429;
      if (rateLimited || p.failures >= threshold) {
        const secs = Math.max(0, cooldownSeconds);
        p.cooldownUntil = now() + secs * 1000;
      }
    },

    recordSuccess(planId) {
      const p = ensure(planId);
      p.failures = 0;
      delete p.cooldownUntil;
    },

    isAvailable(planId) {
      return computeStatus(ensure(planId)) !== 'cooldown';
    },

    status(planId) {
      return computeStatus(ensure(planId));
    },

    snapshot() {
      const out: Record<string, { status: string; failures: number; cooldownUntil?: number }> = {};
      for (const [id, p] of plans) {
        const status = computeStatus(p);
        const entry: { status: string; failures: number; cooldownUntil?: number } = {
          status,
          failures: p.failures,
        };
        if (p.cooldownUntil !== undefined && p.cooldownUntil > now()) {
          entry.cooldownUntil = p.cooldownUntil;
        }
        out[id] = entry;
      }
      return out;
    },
  };
}

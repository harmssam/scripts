import type { HealthTracker } from '../events/health.js';
import type { Config, EquivalenceGroup, Plan } from '../types.js';

export interface PlanCandidate {
  plan: Plan;
  reason: string;
}

/** Module-level round-robin counters keyed by group id. */
const rrCounters = new Map<string, number>();

/** Reset RR state (tests only). */
export function resetRoundRobinCounters(): void {
  rrCounters.clear();
}

function plansById(config: Config): Map<string, Plan> {
  return new Map(config.plans.map((p) => [p.id, p]));
}

function resolveTarget(
  config: Config,
  virtualModel: string
): { targetType: 'group' | 'plan'; targetId: string; via: string } | null {
  const route = config.routes.find((r) => r.model === virtualModel);
  if (route) {
    return {
      targetType: route.targetType,
      targetId: route.targetId,
      via: `route model=${virtualModel}`,
    };
  }
  if (config.defaultRoute) {
    return {
      targetType: config.defaultRoute.targetType,
      targetId: config.defaultRoute.targetId,
      via: 'defaultRoute',
    };
  }
  return null;
}

function candidateForPlan(
  plan: Plan | undefined,
  health: HealthTracker,
  reason: string
): PlanCandidate[] {
  if (!plan || !plan.enabled || !health.isAvailable(plan.id)) {
    return [];
  }
  return [{ plan, reason }];
}

function expandGroup(
  group: EquivalenceGroup,
  byId: Map<string, Plan>,
  health: HealthTracker,
  via: string
): PlanCandidate[] {
  // Preserve planIds order; filter missing, disabled, unavailable
  const available: Plan[] = [];
  for (const id of group.planIds) {
    const plan = byId.get(id);
    if (!plan || !plan.enabled) continue;
    if (!health.isAvailable(plan.id)) continue;
    available.push(plan);
  }

  if (available.length === 0) return [];

  if (group.strategy === 'priority') {
    return available.map((plan, i) => ({
      plan,
      reason: `${via} → group ${group.id} (priority #${i})`,
    }));
  }

  // equal: rotate starting index via module counter
  const n = available.length;
  const counter = rrCounters.get(group.id) ?? 0;
  const start = counter % n;
  rrCounters.set(group.id, counter + 1);

  const ordered: Plan[] = [];
  for (let i = 0; i < n; i++) {
    ordered.push(available[(start + i) % n]!);
  }

  return ordered.map((plan, i) => ({
    plan,
    reason: `${via} → group ${group.id} (equal rr offset=${start} #${i})`,
  }));
}

/**
 * Resolve ordered plan candidates for a virtual model request.
 *
 * Looks up a model route, else `defaultRoute`, else empty.
 * Expands groups with enabled + available plans only; equal uses RR, priority keeps order.
 */
export function resolvePlanCandidates(
  config: Config,
  virtualModel: string,
  health: HealthTracker
): PlanCandidate[] {
  const target = resolveTarget(config, virtualModel);
  if (!target) return [];

  const byId = plansById(config);
  const { targetType, targetId, via } = target;

  if (targetType === 'plan') {
    const plan = byId.get(targetId);
    return candidateForPlan(plan, health, `${via} → plan ${targetId}`);
  }

  const group = config.groups.find((g) => g.id === targetId);
  if (!group) return [];

  return expandGroup(group, byId, health, via);
}

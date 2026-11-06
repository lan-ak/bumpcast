import { parseFlight, type AddedFlight } from "../../onboarding/components/flight";

const HOUR_MS = 3600 * 1000;

/** The test's group: a flight added in the flow that leaves within the next 24 hours, or left up to
 * 12 hours ago (adding it at the gate, or delayed). Taken from the real departure, not the "When is
 * your next flight?" answer: 4 of the 7 people flying within 24 hours on Nov 4 answered "Further out".
 * Past that the flight has landed, and the trial's "today / until you land" no longer fits. */
export function fliesWithin24h(added: AddedFlight | undefined, now = Date.now()): boolean {
  if (!added) return false;
  const until = added.departure.getTime() - now;
  return until <= 24 * HOUR_MS && until > -12 * HOUR_MS;
}

/** The user attribute that keeps the hard trial's flight across launches. The app sets the
 * onboarding as done only when the flow is dismissed, so quitting on the hard page brings the flow
 * back on the next launch; this sends it straight back to the trial instead of the questions. */
export const HARD_FLIGHT_KEY = "onboarding_hard_flight";

/** True while they've left on the hard trial and the flow isn't finished. A notification can open
 * the app on that relaunch and fire a Forecast moments placement in the same second as the flow; the
 * one that loses doesn't show (230F2DA0, Nov 5), so that campaign's top audience skips while this is
 * true. Buying or restoring ends it through the entitlement; the flow clears it once the trial's
 * window has passed (app/index.tsx). */
export const HARD_OPEN_KEY = "onboarding_hard_open";

/** Set when this launch resumed the hard trial (app/index.tsx), so a forecast check that fails
 * then still ends on the trial, not on the closable Plans (app/plans.tsx). */
export const resume = { active: false };

export function saveableFlight(f: AddedFlight): string {
  return JSON.stringify({
    flight_id: f.id,
    origin: f.origin,
    destination: f.destination,
    departure_at: f.departure.toISOString(),
    origin_utc_offset_minutes: f.originOffsetMinutes,
    forecast_unlocks_at: f.unlocks.toISOString(),
  });
}

/** The flight saved by an earlier launch's hard trial, if it's still within the trial's window. */
export function savedHardFlight(user: Record<string, unknown>, now = Date.now()): AddedFlight | undefined {
  const raw = user[HARD_FLIGHT_KEY];
  if (typeof raw !== "string" || !raw) return undefined;
  try {
    const added = parseFlight(JSON.parse(raw) as Record<string, unknown>);
    return fliesWithin24h(added, now) ? added : undefined;
  } catch {
    return undefined;
  }
}

import { useVariables } from "superwall/hooks";

/** Gated placements the app registers (Paywalls.swift). Anything else falls back to generic copy. */
export const PLACEMENTS = [
  "timeline_locked",
  "updates_locked",
  "live_activity_locked",
  "pilot_reports_locked",
  "flight_limit_reached",
  "upgrade_from_settings",
] as const;
export type ProPlacement = (typeof PLACEMENTS)[number];

export type Confidence = "early" | "partly_confirmed" | "confirmed";
export type Grade = "smooth" | "mostly_smooth" | "some_bumps" | "bumpy" | "rough";

export interface FlightContext {
  /** Present only on flight placements. A flight pass needs it, so no flight means no pass. */
  flightID?: string;
  route?: string;
  hours?: number;
  grade?: Grade;
  gradeTitle?: string;
  confidence?: Confidence;
  bumpyMinutes?: number;
}

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);
const num = (v: unknown) => {
  const n = Number(v);
  return v !== undefined && v !== null && v !== "" && Number.isFinite(n) ? n : undefined;
};
const oneOf = <T extends string>(v: unknown, values: readonly T[]) =>
  typeof v === "string" && (values as readonly string[]).includes(v) ? (v as T) : undefined;

/** The placement and flight the paywall was opened for, every read guarded (params are host-owned). */
export function usePlacementContext() {
  const { params, user } = useVariables();
  const placement = oneOf(params.event_name, PLACEMENTS);
  const flight: FlightContext = {
    flightID: str(params.flight_id),
    route: str(params.route),
    hours: num(params.hours_to_departure),
    grade: oneOf(params.grade, ["smooth", "mostly_smooth", "some_bumps", "bumpy", "rough"] as const),
    gradeTitle: str(params.grade_title),
    confidence: oneOf(params.confidence, ["early", "partly_confirmed", "confirmed"] as const),
    bumpyMinutes: num(params.bumpy_minutes),
  };
  const flightLimit = num(user.free_flight_limit);
  const upcoming = num(user.upcoming_flights);
  return { placement, flight, flightLimit, upcoming };
}

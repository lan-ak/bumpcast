// The flight added during the flow and its first forecast, from the app's answers to the
// `add_flight` and `flight_forecast` callbacks (ios/BumpCast/Services/OnboardingFlight.swift).
// Every field is read defensively: the data is host-owned.

export type ForecastState = "ready" | "pending" | "too_early" | "out_of_coverage";

export interface AddedFlight {
  id: string;
  origin: string;
  destination: string;
  departure: Date;
  /** The origin airport's UTC offset at departure, so times read as they do in the app. */
  originOffsetMinutes: number;
  unlocks: Date;
}

export interface FlightForecast {
  state: ForecastState;
  gradeTitle?: string;
  confidence?: "early" | "partly_confirmed" | "confirmed" | "global_outlook";
}

/** `passOffered`: the flight pass was offered after a closed App Store sheet (once per flow). */
export const flight: { added?: AddedFlight; forecast?: FlightForecast; passOffered?: boolean } = {};

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);
const date = (v: unknown) => {
  const d = typeof v === "string" ? new Date(v) : undefined;
  return d && !Number.isNaN(d.getTime()) ? d : undefined;
};

export function parseFlight(data: Record<string, unknown> | undefined): AddedFlight | undefined {
  const id = str(data?.flight_id);
  const origin = str(data?.origin);
  const destination = str(data?.destination);
  const departure = date(data?.departure_at);
  if (!id || !origin || !destination || !departure) return undefined;
  const offset = Number(data?.origin_utc_offset_minutes);
  return {
    id,
    origin,
    destination,
    departure,
    originOffsetMinutes: Number.isFinite(offset) ? offset : -departure.getTimezoneOffset(),
    unlocks: date(data?.forecast_unlocks_at) ?? new Date(departure.getTime() - 48 * 3600 * 1000),
  };
}

const STATES: readonly ForecastState[] = ["ready", "pending", "too_early", "out_of_coverage"];
const CONFIDENCES = ["early", "partly_confirmed", "confirmed", "global_outlook"] as const;

export function parseForecast(data: Record<string, unknown> | undefined): FlightForecast {
  const state = STATES.find((s) => s === data?.state) ?? "pending";
  return {
    state,
    gradeTitle: state === "ready" ? str(data?.grade_title) : undefined,
    confidence: CONFIDENCES.find((c) => c === data?.confidence),
  };
}

const lower = (text: string) => text.replace(/ |\s(?=[AP]M)/g, " ").replace(/AM|PM/g, (m) => m.toLowerCase());

const DAY_MS = 24 * 3600 * 1000;

/** "today", "tomorrow", a weekday within the week, or a date beyond it, for `date` as shown in
 * `timeZone` (UTC for times already shifted to the airport's clock). */
function dayName(date: Date, now: Date, timeZone: string | undefined, short: boolean): string {
  const key = (d: Date) => d.toLocaleDateString("en-CA", { timeZone });
  const days = Math.round((Date.parse(key(date)) - Date.parse(key(now))) / DAY_MS);
  if (days === 0) return "today";
  if (days === 1) return "tomorrow";
  const weekday = short ? "short" : "long";
  return days > 1 && days < 7
    ? date.toLocaleDateString("en-US", { weekday, timeZone })
    : date.toLocaleDateString("en-US", { weekday, month: "short", day: "numeric", timeZone });
}

/** "Tomorrow 8:15 am", in the origin airport's time, as the app shows it. */
export function departureText(f: AddedFlight, now = new Date()): string {
  const shift = (d: Date) => new Date(d.getTime() + f.originOffsetMinutes * 60 * 1000);
  const day = dayName(shift(f.departure), shift(now), "UTC", true);
  const time = lower(shift(f.departure).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }));
  return `${day.charAt(0).toUpperCase()}${day.slice(1)} ${time}`;
}

/** "Tuesday" / "tomorrow" and "9:40 am", in the phone's own time: when they'll get the forecast. */
export function unlockText(f: AddedFlight, now = new Date()): { day: string; time: string } {
  return {
    day: dayName(f.unlocks, now, undefined, false),
    time: lower(f.unlocks.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })),
  };
}

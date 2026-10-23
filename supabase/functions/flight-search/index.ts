// Flight search for the add-flight sheet (free for everyone).
//
//   POST { "number": "B6 23", "date": "2026-10-22" }
//   POST { "origin": "KJFK", "destination": "KLAX", "date": "2026-10-22" }
//
// Returns { state, flights }, where state is found | not_found | not_published | no_schedule
// | unavailable, and each flight is { flight_number, airline_name, origin, destination,
// departure_at, arrival_at, departed, takeoff_at, landed_at, departure_actual } with ICAO
// airports and UTC times. The live fields say where today's flight is: departed (left the gate),
// takeoff_at and landed_at (runway times, only once they've passed: before that they're
// estimates) and departure_actual (when it left the gate); null or false until then. The
// provider key stays here; the app never sees or names the provider.
//
// Secrets: AERODATABOX_API_KEY. Optional AERODATABOX_API_URL (default: the direct API, key in
// x-api-key) and AERODATABOX_KEY_HEADER, as in the worker. A RapidAPI URL switches to its headers.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const DIRECT_URL = "https://api.aerodatabox.com";
const SEARCHES_PER_HOUR = 60;
// No results this far ahead most likely means the airline hasn't published the schedule yet.
const PUBLISHED_HORIZON_DAYS = 60;
// Provider statuses that mean the aircraft has pushed back or taken off (as in the worker).
const DEPARTED = new Set(["Departed", "EnRoute", "Approaching", "Arrived"]);

type Flight = {
  flight_number: string;
  airline_name: string | null;
  origin: string;
  destination: string;
  departure_at: string;
  arrival_at: string | null;
  departed: boolean;
  takeoff_at: string | null;
  landed_at: string | null;
  departure_actual: string | null;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export function normalizeNumber(text: string): string | null {
  const compact = text.toUpperCase().replace(/[\s-]/g, "");
  const m = compact.match(/^([A-Z]{3}|[A-Z0-9]{2})(\d{1,4})([A-Z]?)$/);
  if (!m || !/[A-Z]/.test(m[1])) return null;
  return `${m[1]} ${parseInt(m[2], 10)}${m[3]}`;
}

// '2026-10-22 11:15Z' -> '2026-10-22T11:15:00Z' (no milliseconds, for the app's ISO 8601 decoder)
function utc(t: { utc?: string } | undefined): string | null {
  if (!t?.utc) return null;
  const date = new Date(t.utc.replace(" ", "T"));
  return isNaN(date.getTime()) ? null : date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// A runway time counts once it has passed; until then it's the airline's estimate.
function passed(t: string | null): string | null {
  return t && Date.parse(t) <= Date.now() ? t : null;
}

// deno-lint-ignore no-explicit-any
function toFlight(f: any): Flight | null {
  const dep = f.departure ?? {};
  const arr = f.arrival ?? {};
  const departure = utc(dep.scheduledTime);
  if (!dep.airport?.icao || !arr.airport?.icao || !departure) return null;
  const takeoff = passed(utc(dep.runwayTime));
  const departed = DEPARTED.has(f.status) || takeoff !== null;
  const arrived = f.status === "Arrived";
  return {
    flight_number: normalizeNumber(f.number ?? "") ?? f.number,
    airline_name: f.airline?.name ?? null,
    origin: dep.airport.icao,
    destination: arr.airport.icao,
    departure_at: departure,
    arrival_at: utc(arr.scheduledTime),
    departed,
    takeoff_at: departed ? takeoff : null,
    // Only once it has left: a stale arrival estimate for a plane still at the gate isn't a landing.
    // "Arrived" without a runway time (only gate times known) is still a landing.
    landed_at: departed
      ? passed(utc(arr.runwayTime)) ??
        (arrived
          ? passed(utc(arr.revisedTime)) ?? passed(utc(arr.scheduledTime)) ??
            new Date().toISOString().replace(/\.\d{3}Z$/, "Z")
          : null)
      : null,
    departure_actual: departed ? utc(dep.revisedTime) ?? takeoff : null,
  };
}

async function provider(path: string, params: Record<string, string>) {
  const key = Deno.env.get("AERODATABOX_API_KEY");
  if (!key) throw new Error("not configured");
  const base = (Deno.env.get("AERODATABOX_API_URL") ?? DIRECT_URL).replace(/\/$/, "");
  const headers: Record<string, string> = base.includes("rapidapi")
    ? { "X-RapidAPI-Key": key, "X-RapidAPI-Host": new URL(base).host }
    : { [Deno.env.get("AERODATABOX_KEY_HEADER") ?? "x-api-key"]: key };
  const res = await fetch(`${base}${path}?${new URLSearchParams(params)}`, { headers });
  if (res.status === 204 || res.status === 404) return null;
  if (!res.ok) throw new Error(`provider ${res.status}`);
  return await res.json();
}

function daysAhead(date: string): number {
  return (Date.parse(`${date}T12:00:00Z`) - Date.now()) / 86_400_000;
}

async function byNumber(number: string, date: string) {
  const raw = await provider(`/flights/number/${encodeURIComponent(number.replace(" ", ""))}/${date}`, {
    withAircraftImage: "false",
    withLocation: "false",
    dateLocalRole: "Departure",
  });
  // deno-lint-ignore no-explicit-any
  const operating = (raw ?? []).filter((f: any) => f.codeshareStatus !== "IsCodeshared");
  const flights = (operating.length ? operating : raw ?? []).map(toFlight).filter(Boolean) as Flight[];
  if (flights.length) return { state: "found", flights };
  return { state: daysAhead(date) > PUBLISHED_HORIZON_DAYS ? "not_published" : "not_found", flights: [] };
}

async function byRoute(origin: string, destination: string, date: string) {
  // The departures list takes local-time windows of up to 12 hours.
  const windows = [["00:00", "11:59"], ["12:00", "23:59"]];
  const pages = await Promise.all(
    windows.map(([from, to]) =>
      provider(`/flights/airports/icao/${origin}/${date}T${from}/${date}T${to}`, {
        direction: "Departure",
        withLeg: "true",
        withCancelled: "false",
        withCodeshared: "false",
        withCargo: "false",
        withPrivate: "false",
        withLocation: "false",
      })
    ),
  );
  // The departures list leaves out the departure airport: it's the one asked about.
  const departures = pages
    // deno-lint-ignore no-explicit-any
    .flatMap((p: any) => p?.departures ?? [])
    // deno-lint-ignore no-explicit-any
    .map((f: any) => ({ ...f, departure: { ...f.departure, airport: { icao: origin } } }));
  if (!departures.length) {
    return { state: daysAhead(date) > PUBLISHED_HORIZON_DAYS ? "not_published" : "no_schedule", flights: [] };
  }
  const seen = new Set<string>();
  const flights = departures
    // deno-lint-ignore no-explicit-any
    .filter((f: any) => f.arrival?.airport?.icao === destination && f.codeshareStatus !== "IsCodeshared")
    .map(toFlight)
    .filter((f: Flight | null): f is Flight => f !== null && !seen.has(f.flight_number) && !!seen.add(f.flight_number))
    .sort((a: Flight, b: Flight) => a.departure_at.localeCompare(b.departure_at));
  return { state: flights.length ? "found" : "not_found", flights };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const auth = req.headers.get("Authorization") ?? "";
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return json({ error: "sign in first" }, 401);

  // A light per-user limit so one account can't run through the monthly quota.
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const since = new Date(Date.now() - 3_600_000).toISOString();
  const { count } = await admin.from("flight_searches").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).gte("created_at", since);
  if ((count ?? 0) >= SEARCHES_PER_HOUR) return json({ state: "unavailable", flights: [] }, 429);

  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad request" }, 400);
  }
  const date = String(body.date ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ error: "date must be YYYY-MM-DD" }, 400);

  try {
    await admin.from("flight_searches").insert({ user_id: user.id });
    if (body.number !== undefined) {
      const number = normalizeNumber(String(body.number));
      if (!number) return json({ state: "not_found", flights: [] });
      return json(await byNumber(number, date));
    }
    const origin = String(body.origin ?? "").toUpperCase();
    const destination = String(body.destination ?? "").toUpperCase();
    if (!/^[A-Z0-9]{4}$/.test(origin) || !/^[A-Z0-9]{4}$/.test(destination)) {
      return json({ error: "origin and destination are ICAO codes" }, 400);
    }
    return json(await byRoute(origin, destination, date));
  } catch (error) {
    console.error("flight search failed", error);
    return json({ state: "unavailable", flights: [] });
  }
});

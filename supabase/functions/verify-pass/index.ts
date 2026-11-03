// Checks a flight pass with Apple before it counts (from app 1.0.4).
//
//   POST { "transaction_id": "2000001253369850", "flight_id": "<uuid>", "product_id": "bumpcast_flight_pass" }
//     from the app, with the user's token. Verifies the transaction and saves the pass.
//   POST { "sweep": true }
//     from the worker, with the service role key. Verifies passes that apps up to 1.0.3 inserted
//     themselves (verified_at and rejected_at both null).
//
// A transaction counts when Apple's App Store Server API knows it, it's for this app and one of
// the pass products, and it hasn't been refunded. Production is asked first, then the sandbox
// (TestFlight and Xcode purchases). Superwall test-store purchases have UUID ids and no Apple
// transaction: they count only while ALLOW_TEST_STORE_PASSES is "1".
//
// Answers to the app: 200 { status: "verified" } · 422 { status: "rejected", reason } (another
// app's or product's transaction, a refund, or a test-store purchase while those are off; don't
// send it again) · 401/403 · 503 { status: "unavailable" } (Apple unreachable or doesn't know the
// transaction yet, or this function isn't configured; the app keeps the pass queued and tries
// again on a later sync).
//
// Secrets: APPLE_IAP_KEY_ID, APPLE_IAP_ISSUER_ID, APPLE_IAP_PRIVATE_KEY (the .p8 file's contents,
// an In-App Purchase key from App Store Connect > Users and Access > Integrations), optional
// APPLE_BUNDLE_ID (default ca.akinyemi.bumpcast) and ALLOW_TEST_STORE_PASSES.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { check, config, type Config, type Outcome, type Pass, PASS_PRODUCTS, UUID } from "./apple.ts";

const SWEEP_LIMIT = 50;
// A pass Apple can't be reached about is tried again on later sweeps (the worker sweeps at most every
// 10 minutes), up to this many times: about 8 hours of Apple being down.
const MAX_ATTEMPTS = 48;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/** Saves what Apple said about a pass row. */
async function settle(admin: SupabaseClient, pass: Pass, outcome: Outcome, attempts: number) {
  const now = new Date().toISOString();
  const fields = outcome.status === "verified"
    ? { verified_at: now, environment: outcome.environment, verify_error: null, rejected_at: null }
    : outcome.status === "rejected"
    ? { rejected_at: now, verify_error: outcome.reason }
    : { verify_error: outcome.reason };
  await admin.from("flight_passes").upsert(
    { ...pass, ...fields, verify_attempts: attempts },
    { onConflict: "transaction_id" },
  );
}

/** Whether the caller holds a service key. The worker's legacy service-role JWT and the project's
 * newer secret keys are different strings, so a key that isn't one we hold is tried as an admin. */
async function isServiceCaller(auth: string, url: string): Promise<boolean> {
  const token = auth.replace(/^Bearer /, "");
  if (!token) return false;
  const known = [Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")];
  try {
    known.push(...Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}") as Record<string, string>));
  } catch { /* not set */ }
  if (known.includes(token)) return true;
  const { error } = await createClient(url, token, { auth: { persistSession: false } }).auth.admin.listUsers({ perPage: 1 });
  return !error;
}

async function sweep(admin: SupabaseClient, cfg: Config) {
  const { data, error } = await admin.from("flight_passes")
    .select("transaction_id,flight_id,user_id,product_id,verify_attempts")
    .is("verified_at", null).is("rejected_at", null).lt("verify_attempts", MAX_ATTEMPTS)
    .order("created_at").limit(SWEEP_LIMIT);
  if (error) throw error;
  const counts = { verified: 0, rejected: 0, unavailable: 0 };
  for (const { verify_attempts, ...pass } of data ?? []) {
    const outcome = await check(pass, cfg);
    counts[outcome.status]++;
    await settle(admin, pass, outcome, verify_attempts + 1);
  }
  return counts;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth = req.headers.get("Authorization") ?? "";
  const admin = createClient(url, serviceKey);

  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad request" }, 400);
  }

  const cfg = await config().catch((error) => {
    console.error("verify-pass: bad Apple key", error);
    return null;
  });
  if (!cfg) return json({ status: "unavailable", reason: "not configured" }, 503);

  if (body.sweep === true) {
    if (!(await isServiceCaller(auth, url))) return json({ error: "service role only" }, 403);
    try {
      return json(await sweep(admin, cfg));
    } catch (error) {
      console.error("verify-pass sweep failed", error);
      return json({ status: "unavailable" }, 503);
    }
  }

  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return json({ error: "sign in first" }, 401);

  const pass: Pass = {
    transaction_id: String(body.transaction_id ?? ""),
    flight_id: String(body.flight_id ?? ""),
    product_id: String(body.product_id ?? ""),
    user_id: user.id,
  };
  if (!pass.transaction_id || !UUID.test(pass.flight_id) || !PASS_PRODUCTS.has(pass.product_id)) {
    return json({ error: "transaction_id, flight_id and a pass product_id are required" }, 400);
  }

  // The caller's own flight (their token, so RLS decides).
  const { data: flight } = await asUser.from("flights").select("id").eq("id", pass.flight_id).maybeSingle();
  if (!flight) return json({ error: "not your flight" }, 403);

  // One transaction unlocks one flight: a transaction already saved stays where it is.
  const { data: existing } = await admin.from("flight_passes")
    .select("user_id,flight_id,verified_at,rejected_at,verify_attempts").eq("transaction_id", pass.transaction_id).maybeSingle();
  if (existing?.verified_at) {
    return existing.user_id === user.id && existing.flight_id === pass.flight_id
      ? json({ status: "verified" })
      : json({ status: "rejected", reason: "transaction already used" }, 422);
  }
  if (existing && existing.user_id !== user.id) return json({ status: "rejected", reason: "transaction already used" }, 422);

  const outcome = await check(pass, cfg);
  await settle(admin, pass, outcome, (existing?.verify_attempts ?? 0) + 1);
  switch (outcome.status) {
    case "verified":
      return json({ status: "verified" });
    case "rejected":
      return json({ status: "rejected", reason: outcome.reason }, 422);
    default:
      console.error("verify-pass: Apple unavailable", outcome.reason);
      return json({ status: "unavailable" }, 503);
  }
});

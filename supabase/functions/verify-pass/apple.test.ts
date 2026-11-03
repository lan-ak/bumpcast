// deno test supabase/functions/verify-pass/apple.test.ts
import { assertEquals } from "jsr:@std/assert@1.0.13";
import { appleToken, type AppleTransaction, check, type Config, judge, jwsPayload } from "./apple.ts";

const BUNDLE = "ca.akinyemi.bumpcast";
const cfg: Config = { token: "t", bundleId: BUNDLE, allowTestStore: false };
const pass = { transaction_id: "2000001253369850", product_id: "bumpcast_flight_pass_999" };
const tx: AppleTransaction = {
  transactionId: "2000001253369850",
  bundleId: BUNDLE,
  productId: "bumpcast_flight_pass_999",
  type: "Consumable",
  environment: "Production",
};

const b64 = (value: unknown) => btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const signed = (t: AppleTransaction) => `${b64({ alg: "ES256" })}.${b64(t)}.sig`;

/** A fetch that answers per host: a transaction, a status, or a thrown error. */
function apple(answers: Record<string, AppleTransaction | number | "throw">): typeof fetch {
  return ((input: string | URL | Request) => {
    const url = String(input);
    const answer = Object.entries(answers).find(([host]) => url.includes(host))?.[1] ?? 404;
    if (answer === "throw") return Promise.reject(new Error("offline"));
    if (typeof answer === "number") return Promise.resolve(new Response("{}", { status: answer }));
    return Promise.resolve(new Response(JSON.stringify({ signedTransactionInfo: signed(answer) })));
  }) as typeof fetch;
}

Deno.test("a pass for this app counts", () => {
  assertEquals(judge(tx, pass, BUNDLE), { status: "verified", environment: "Production" });
});

Deno.test("refunds, other apps, other products and mismatches don't", () => {
  assertEquals(judge({ ...tx, revocationDate: 1 }, pass, BUNDLE).status, "rejected");
  assertEquals(judge({ ...tx, bundleId: "com.other" }, pass, BUNDLE).status, "rejected");
  assertEquals(judge({ ...tx, productId: "bumpcast_pro_monthly" }, { ...pass, product_id: "bumpcast_pro_monthly" }, BUNDLE).status, "rejected");
  assertEquals(judge(tx, { ...pass, product_id: "bumpcast_flight_pass" }, BUNDLE).status, "rejected");
  assertEquals(judge({ ...tx, transactionId: "1" }, pass, BUNDLE).status, "rejected");
});

Deno.test("reads a JWS payload", () => {
  assertEquals(jwsPayload<AppleTransaction>(signed(tx)).productId, "bumpcast_flight_pass_999");
});

Deno.test("asks production, then the sandbox", async () => {
  assertEquals(await check(pass, cfg, apple({ "storekit.itunes": tx })), { status: "verified", environment: "Production" });
  const sandbox = { ...tx, environment: "Sandbox" };
  assertEquals(await check(pass, cfg, apple({ "storekit-sandbox": sandbox })), { status: "verified", environment: "Sandbox" });
  // Unknown to both: kept and asked again later, never rejected.
  assertEquals(await check(pass, cfg, apple({})), { status: "unavailable", reason: "unknown to Apple" });
});

Deno.test("Apple down or failing is unavailable, so it's tried again", async () => {
  assertEquals((await check(pass, cfg, apple({ "storekit.itunes": 500 }))).status, "unavailable");
  assertEquals((await check(pass, cfg, apple({ "storekit.itunes": "throw" }))).status, "unavailable");
  assertEquals((await check(pass, cfg, apple({ "storekit.itunes": 401 }))).status, "unavailable");
});

Deno.test("test-store passes count only while allowed", async () => {
  const test = { transaction_id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", product_id: "bumpcast_flight_pass" };
  assertEquals((await check(test, cfg, apple({}))).status, "rejected");
  assertEquals(await check(test, { ...cfg, allowTestStore: true }, apple({})), { status: "verified", environment: "TestStore" });
  assertEquals((await check({ ...pass, transaction_id: "abc" }, cfg, apple({}))).status, "rejected");
});

Deno.test("signs an ES256 token Apple can check", async () => {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  const token = await appleToken("KEY123", "issuer-uuid", pem, BUNDLE);
  const [header, payload, signature] = token.split(".");
  assertEquals(jwsPayload<{ kid: string }>(`x.${header}.y`).kid, "KEY123");
  const claims = jwsPayload<{ aud: string; bid: string; iss: string }>(token);
  assertEquals([claims.aud, claims.bid, claims.iss], ["appstoreconnect-v1", BUNDLE, "issuer-uuid"]);
  const raw = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/").padEnd(88, "=")), (c) => c.charCodeAt(0));
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, keys.publicKey, raw, new TextEncoder().encode(`${header}.${payload}`));
  assertEquals(ok, true);
});

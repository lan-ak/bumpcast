// Asking Apple's App Store Server API whether a transaction is a flight pass for this app.
// Kept apart from index.ts so tests can import it without starting the server.

export const PASS_PRODUCTS = new Set(["bumpcast_flight_pass", "bumpcast_flight_pass_999"]);
const DEFAULT_BUNDLE_ID = "ca.akinyemi.bumpcast";
const HOSTS = {
  Production: "https://api.storekit.itunes.apple.com",
  Sandbox: "https://api.storekit-sandbox.itunes.apple.com",
} as const;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type Pass = { transaction_id: string; flight_id: string; user_id: string; product_id: string };

/** The transaction as Apple describes it (the JWS payload of signedTransactionInfo). */
export type AppleTransaction = {
  transactionId: string;
  bundleId: string;
  productId: string;
  type?: string;
  revocationDate?: number;
  environment?: string;
};

export type Outcome =
  | { status: "verified"; environment: string }
  | { status: "rejected"; reason: string }
  | { status: "unavailable"; reason: string };

/** Whether Apple's record of a transaction makes it a pass for this app. */
export function judge(tx: AppleTransaction, pass: Pick<Pass, "transaction_id" | "product_id">, bundleId: string): Outcome {
  if (tx.bundleId !== bundleId) return { status: "rejected", reason: "another app's transaction" };
  if (String(tx.transactionId) !== pass.transaction_id) return { status: "rejected", reason: "transaction id mismatch" };
  if (!PASS_PRODUCTS.has(tx.productId)) return { status: "rejected", reason: `not a pass: ${tx.productId}` };
  if (tx.productId !== pass.product_id) return { status: "rejected", reason: "product mismatch" };
  if (tx.revocationDate) return { status: "rejected", reason: "refunded" };
  return { status: "verified", environment: tx.environment ?? "Production" };
}

/** The payload of a JWS. Apple's answer comes straight from Apple over TLS, to our own signed
 * request, so its certificate chain isn't checked again here. */
export function jwsPayload<T>(jws: string): T {
  const part = jws.split(".")[1];
  if (!part) throw new Error("not a JWS");
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(base64), (c) => c.charCodeAt(0))));
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** The App Store Server API's bearer token: ES256, signed with the In-App Purchase key. */
export async function appleToken(keyID: string, issuerID: string, pem: string, bundleId: string): Promise<string> {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: "ES256", kid: keyID, typ: "JWT" })}.${
    encode({ iss: issuerID, iat: now, exp: now + 1200, aud: "appstoreconnect-v1", bid: bundleId })
  }`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

export type Config = { token: string; bundleId: string; allowTestStore: boolean };

export async function config(): Promise<Config | null> {
  const keyID = Deno.env.get("APPLE_IAP_KEY_ID");
  const issuerID = Deno.env.get("APPLE_IAP_ISSUER_ID");
  const pem = Deno.env.get("APPLE_IAP_PRIVATE_KEY");
  const bundleId = Deno.env.get("APPLE_BUNDLE_ID") ?? DEFAULT_BUNDLE_ID;
  const allowTestStore = Deno.env.get("ALLOW_TEST_STORE_PASSES") === "1";
  if (!keyID || !issuerID || !pem) return null;
  return { token: await appleToken(keyID, issuerID, pem, bundleId), bundleId, allowTestStore };
}

/** Asks Apple about one pass: production first, then the sandbox. */
export async function check(
  pass: Pick<Pass, "transaction_id" | "product_id">,
  cfg: Config,
  fetcher: typeof fetch = fetch,
): Promise<Outcome> {
  if (UUID.test(pass.transaction_id)) {
    return cfg.allowTestStore
      ? { status: "verified", environment: "TestStore" }
      : { status: "rejected", reason: "test-store purchase" };
  }
  if (!/^\d{1,30}$/.test(pass.transaction_id)) return { status: "rejected", reason: "not an App Store transaction id" };
  for (const [environment, host] of Object.entries(HOSTS)) {
    let response: Response;
    try {
      response = await fetcher(`${host}/inApps/v1/transactions/${pass.transaction_id}`, {
        headers: { Authorization: `Bearer ${cfg.token}` },
      });
    } catch (error) {
      return { status: "unavailable", reason: `${environment}: ${error}` };
    }
    // Not found here: a sandbox transaction is unknown to production, so ask the sandbox next.
    if (response.status === 404) continue;
    if (!response.ok) return { status: "unavailable", reason: `${environment} answered ${response.status}` };
    const body = await response.json();
    const tx = jwsPayload<AppleTransaction>(body.signedTransactionInfo);
    return judge({ ...tx, environment: tx.environment ?? environment }, pass, cfg.bundleId);
  }
  // Unknown to both. Never a rejection: a genuine buyer mustn't lose a pass to a lookup hiccup.
  // It stays unverified (not counted off the phone) and is asked about again later.
  return { status: "unavailable", reason: "unknown to Apple" };
}


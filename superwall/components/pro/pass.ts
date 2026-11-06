/**
 * The $9.99 pass (`pass`) needs 1.0.4 or later: older builds only unlock a flight for the $3.99 one
 * (`pass399`), so a $9.99 purchase there would charge and unlock nothing. Unknown versions get $3.99.
 */
export function passProduct(appVersion: unknown): "pass" | "pass399" {
  const [major, minor, patch] = String(appVersion ?? "").split(".").map(Number);
  if (![major, minor].every(Number.isFinite)) return "pass399";
  const v = [major, minor, Number.isFinite(patch) ? patch : 0];
  return v[0] * 1e6 + v[1] * 1e3 + v[2] >= 1_000_004 ? "pass" : "pass399";
}

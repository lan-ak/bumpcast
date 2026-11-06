/**
 * What Yearly saves over twelve months of Monthly, as a whole percent rounded down (so it never
 * overstates). 0 when either price is missing, and the badge is left off.
 */
export function savePercent(yearly: { rawPrice?: unknown } | undefined, monthly: { rawPrice?: unknown } | undefined): number {
  const y = Number(yearly?.rawPrice);
  const m = Number(monthly?.rawPrice);
  if (!(y > 0 && m > 0)) return 0;
  return Math.max(0, Math.floor((1 - y / (m * 12)) * 100));
}

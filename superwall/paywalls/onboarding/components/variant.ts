// The hard-vs-soft test on the flight paywall. The same flow ships as two paywalls in the
// Onboarding campaign: `onboarding` (hard: the flight paywall can't be closed) and
// `onboarding-soft` (it can). Each paywall's layout.tsx sets this before any page renders.
// `onboarding-near` sets `near` too: the soft flow with a trial and a pass for flights within 24h.
export const variant = { soft: false, near: false };

/** Saved as the `onboarding_paywall_variant` user attribute, so later purchases can be split by it. */
export const variantName = () => (variant.near ? "near-trial" : variant.soft ? "soft" : "hard");

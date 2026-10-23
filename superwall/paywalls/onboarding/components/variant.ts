// The hard-vs-soft test on the flight paywall. The same flow ships as two paywalls in the
// Onboarding campaign: `onboarding` (hard: the flight paywall and the pass offer can't be closed)
// and `onboarding-soft` (both can). Each paywall's layout.tsx sets this before any page renders.
export const variant = { soft: false };

/** Saved as the `onboarding_paywall_variant` user attribute, so later purchases can be split by it. */
export const variantName = () => (variant.soft ? "soft" : "hard");

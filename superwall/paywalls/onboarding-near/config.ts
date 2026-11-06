import { definePaywall } from "superwall/config";

// The near-flier test (2026-11-04): the soft onboarding flow, page for page, except the flight
// paywall. A flight leaving within 24 hours gets one plan, Yearly with a 3-day free trial, and can't be
// closed; any other flight gets Yearly and Monthly with no trial, closable. Both lay out what happens next as a timeline.
export default definePaywall({
  name: "Onboarding · near-flier trial",
  products: {
    // As on onboarding-soft: $49.99/year with no trial, and Monthly, for everyone not flying today.
    annual: "bumpcast_pro_annual_4999_3d",
    monthly: "bumpcast_pro_monthly",
    // Near fliers only: $39.99/year with a 3-day free trial (its intro offer is live in all 175
    // territories; the $49.99 product's was deleted on Nov 3).
    trial: "bumpcast_pro_annual_3999_3d",
  },
  transition: "slide",
  // Matches the dawn sky (light) and the night sky (dark) so the load never flashes.
  background: { light: "#EAE0DA", dark: "#121D31" },
  presentation: { style: "fullscreen" },
  featureGating: "nonGated",
  // Every page fits the screen; scrolling only let the whole flow rubber-band under a drag.
  scrollEnabled: false,
});

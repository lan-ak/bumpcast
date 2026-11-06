import { definePaywall } from "superwall/config";

// The near-flier test (2026-11-04): the soft onboarding flow, page for page, except the flight
// paywall. A flight leaving within 24 hours gets its forecast blurred under "Unlock to see", with
// Yearly or a pass for that flight, and can't be closed; any other flight gets Yearly and Monthly
// with no trial, closable, under a timeline of what happens next.
export default definePaywall({
  name: "Onboarding · near-flier offer",
  products: {
    // $49.99/year with no trial (its intro offer was removed on Nov 3, whatever the ID says).
    annual: "bumpcast_pro_annual_4999_3d",
    monthly: "bumpcast_pro_monthly",
    // Near fliers only: the $9.99 pass on 1.0.4 and later, the $3.99 one for older builds
    // (components/pro/pass.ts).
    pass: "bumpcast_flight_pass_999",
    pass399: "bumpcast_flight_pass",
  },
  transition: "slide",
  // Matches the dawn sky (light) and the night sky (dark) so the load never flashes.
  background: { light: "#EAE0DA", dark: "#121D31" },
  presentation: { style: "fullscreen" },
  featureGating: "nonGated",
  // Every page fits the screen; scrolling only let the whole flow rubber-band under a drag.
  scrollEnabled: false,
});

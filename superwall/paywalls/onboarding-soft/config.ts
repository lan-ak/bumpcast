import { definePaywall } from "superwall/config";

// The soft side of the hard-vs-soft test (see paywalls/onboarding/components/variant.ts): the same
// flow as `onboarding`, except the flight paywall and the pass offer can be closed.
// The name must stay "Onboarding" while people are still on 1.0 or 1.0.1: they wait for the
// webview of the paywall with exactly that name before they present the flow. From 1.0.2 the app
// asks the `onboarding` placement which paywall it shows, so any name works. Until then the
// dashboard tells the two apart by identifier (`onboarding-soft`) and id.

export default definePaywall({
  name: "Onboarding",
  products: {
    annual: "bumpcast_pro_annual",
    monthly: "bumpcast_pro_monthly",
    // The flight pass, sold on the flight page to people flying in the next 3 days.
    pass: "bumpcast_flight_pass",
  },
  transition: "slide",
  // Matches the dawn sky (light) and the night sky (dark) so the load never flashes.
  background: { light: "#EAE0DA", dark: "#121D31" },
  presentation: { style: "fullscreen" },
  featureGating: "nonGated",
  // Every page fits the screen; scrolling only let the whole flow rubber-band under a drag.
  scrollEnabled: false,
});

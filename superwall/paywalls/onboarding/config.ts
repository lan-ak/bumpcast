import { definePaywall } from "superwall/config";

// The hard side of the hard-vs-soft test (see components/variant.ts): the flight paywall can't
// be closed. `onboarding-soft` is the same flow with it closable.
export default definePaywall({
  name: "Onboarding · hard",
  products: {
    // $39.99/year with a 3-day free trial: the yearly plan on Plans and the flight paywall.
    annual: "bumpcast_pro_annual_3999_3d",
    // $39.99/year with a 7-day free trial: the "Need more time?" offer when someone closes the
    // App Store sheet on the yearly plan (components/more-time.tsx).
    annual7: "bumpcast_pro_annual",
    monthly: "bumpcast_pro_monthly",
  },
  transition: "slide",
  // Matches the dawn sky (light) and the night sky (dark) so the load never flashes.
  background: { light: "#EAE0DA", dark: "#121D31" },
  presentation: { style: "fullscreen" },
  featureGating: "nonGated",
  // Every page fits the screen; scrolling only let the whole flow rubber-band under a drag.
  scrollEnabled: false,
});

import { definePaywall } from "superwall/config";

// The hard side of the hard-vs-soft test (see components/variant.ts): the flight paywall can't
// be closed. `onboarding-soft` is the same flow with it closable.
export default definePaywall({
  name: "Onboarding · hard",
  products: {
    // $49.99/year with no trial (its intro offer was removed on Nov 3, whatever the ID says): the
    // yearly plan on Plans and the flight paywall, badged with what it saves over Monthly.
    annual: "bumpcast_pro_annual_4999_3d",
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

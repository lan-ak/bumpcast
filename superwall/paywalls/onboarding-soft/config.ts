import { definePaywall } from "superwall/config";

// The soft side of the hard-vs-soft test (see paywalls/onboarding/components/variant.ts): the same
// flow as `onboarding`, except the flight paywall can be closed.
// The app finds the flow by asking the `onboarding` placement which paywall it shows (1.0.2 on),
// so the names are free. 1.0 and 1.0.1 waited for one named "Onboarding", but only on a first
// launch, and the App Store has served 1.0.2 or later to new installs since Oct 25.

export default definePaywall({
  name: "Onboarding · soft",
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

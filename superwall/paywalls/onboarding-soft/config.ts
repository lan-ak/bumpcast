import { definePaywall } from "superwall/config";

// The soft side of the hard-vs-soft test (see paywalls/onboarding/components/variant.ts): the same
// flow as `onboarding`, except the flight paywall can be closed.
// The app finds the flow by asking the `onboarding` placement which paywall it shows (1.0.2 on),
// so the names are free. 1.0 and 1.0.1 waited for one named "Onboarding", but only on a first
// launch, and the App Store has served 1.0.2 or later to new installs since Oct 25.

export default definePaywall({
  name: "Onboarding · soft",
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

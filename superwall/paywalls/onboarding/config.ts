import { definePaywall } from "superwall/config";

export default definePaywall({
  name: "Onboarding",
  products: {
    annual: "bumpcast_pro_annual",
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

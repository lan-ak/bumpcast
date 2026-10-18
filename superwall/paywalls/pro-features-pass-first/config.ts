import { definePaywall } from "superwall/config";

// Gated paywall for the Pro features campaign, flight pass first (when the placement is about a
// flight; otherwise it's the same as pro-features). The A/B partner of pro-features.
export default definePaywall({
  name: "Pro features · flight pass leads",
  products: {
    annual: "bumpcast_pro_annual",
    monthly: "bumpcast_pro_monthly",
    pass: "bumpcast_flight_pass",
  },
  background: { light: "#F4F7FA", dark: "#142131" },
  presentation: { style: "modal" },
  featureGating: "gated",
  scrollEnabled: true,
});

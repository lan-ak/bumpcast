import { definePaywall } from "superwall/config";

// Gated paywall for the Pro features campaign, subscription first. Its A/B partner is
// pro-features-pass-first, identical except the flight pass leads.
export default definePaywall({
  name: "Pro features · subscription leads",
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

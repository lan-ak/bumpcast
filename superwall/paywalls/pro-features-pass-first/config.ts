import { definePaywall } from "superwall/config";

// Gated paywall for the Pro features campaign, flight pass first (when the placement is about a
// flight; otherwise it's the same as pro-features). The A/B partner of pro-features.
export default definePaywall({
  name: "Pro features · flight pass leads",
  products: {
    // $49.99/year with no trial (its intro offer was removed on Nov 3, whatever the ID says),
    // badged with what it saves over Monthly, as in onboarding.
    annual: "bumpcast_pro_annual_4999_3d",
    monthly: "bumpcast_pro_monthly",
    // $9.99 flight pass on 1.0.4 and later; the $3.99 one for older builds (components/pro/paywall.tsx).
    pass: "bumpcast_flight_pass_999",
    pass399: "bumpcast_flight_pass",
  },
  background: { light: "#F4F7FA", dark: "#142131" },
  presentation: { style: "modal" },
  featureGating: "gated",
  scrollEnabled: true,
});

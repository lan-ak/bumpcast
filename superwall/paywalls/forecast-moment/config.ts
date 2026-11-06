import { definePaywall } from "superwall/config";

// Soft paywall for the Forecast moments campaign (first_grade_viewed, forecast_ready_opened,
// update_opened). Shows the user's own forecast and sells the rest of it; always closable.
export default definePaywall({
  name: "Forecast moment",
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
  featureGating: "nonGated",
  scrollEnabled: true,
});

import { definePaywall } from "superwall/config";

// Soft paywall for the Forecast moments campaign (first_grade_viewed, forecast_ready_opened,
// update_opened). Shows the user's own forecast and sells the rest of it; always closable.
export default definePaywall({
  name: "Forecast moment",
  products: {
    annual: "bumpcast_pro_annual",
    monthly: "bumpcast_pro_monthly",
    pass: "bumpcast_flight_pass",
  },
  background: { light: "#F4F7FA", dark: "#142131" },
  presentation: { style: "modal" },
  featureGating: "nonGated",
  scrollEnabled: true,
});

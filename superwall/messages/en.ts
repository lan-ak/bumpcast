// Shared by every paywall. A paywall's own messages/en.ts layers over this one.
export default {
  pro: {
    close: "Close",
    restore: "Restore",
    restoreFailed: "Nothing to restore, or the App Store couldn't be reached.",
    terms: "Terms",
    privacy: "Privacy",

    // Headlines per placement (params.event_name). `fallback` covers anything else.
    title: {
      timeline_locked: "See exactly when the bumps are.",
      updates_locked: "Know the moment your forecast changes.",
      live_activity_locked: "Get your bump countdown ready.",
      pilot_reports_locked: "See what pilots are feeling now.",
      flight_limit_reached: "Keep every flight covered.",
      upgrade_from_settings: "Fly knowing what's coming.",
      fallback: "Fly knowing what's coming.",
    },

    featureTimeline: "Exactly when the bumps are, and for how long",
    featureUpdates: "Your forecast updates as your flight changes: at 24, 6 and 2 hours, after a delay, and when it's confirmed",
    featureLive: "A countdown to each bump on your Lock Screen, offline",
    featurePilots: "Live pilot reports on the map",
    featureFlights: "As many upcoming flights as you like",
    // Coverage, side by side. Never "forecasts worldwide" without the beta qualifier.
    coverageUS: "Detailed, hourly forecasts for US flights",
    coverageGlobal: "Global outlook (beta) for international flights: approximate, updated every 6 hours",

    yearly: "Yearly",
    monthly: "Monthly",
    perYear: "per year",
    perMonth: "per month",
    monthlyEquivalent: "{price}/month",
    cancelAnytime: "Cancel anytime",
    trialBadge: "{days} days free",
    thisFlight: "This flight",
    oneTime: "one time",
    noSubscription: "No subscription",

    ctaTrial: "Start {days}-day free trial",
    ctaSubscribe: "Subscribe",
    ctaPass: "Unlock this flight · {price}",
    ctaPassBare: "Unlock this flight",
    altPass: "Or unlock just this flight · {price}",
    altPassBare: "Or unlock just this flight",
    altTrial: "Or try Pro free for {days} days",
    altPro: "Or get Pro for every flight",
    moreOptions: "More options",

    legalTrial: "Free for {days} days, then {price}/year. Renews automatically. Cancel anytime in Settings.",
    legalAnnual: "{price}/year. Renews automatically. Cancel anytime in Settings.",
    legalMonthly: "{price}/month. Renews automatically. Cancel anytime in Settings.",
    legalBare: "Renews automatically. Cancel anytime in Settings.",
    legalPass: "The flight pass is a one-time purchase and doesn't renew.",

    // Shorter lines for the forecast moment, where the flight ticket takes the room.
    short: {
      featureTimeline: "When the bumps are, and for how long",
      featureUpdates: "Updates as your flight changes",
      featureLive: "Bump countdown on your Lock Screen",
      featurePilots: "Live pilot reports",
      featureFlights: "Unlimited upcoming flights",
      coverageUS: "Hourly detail for US flights",
      coverageGlobal: "Global outlook (beta) elsewhere: approximate",
      legalPass: "One-time purchase. Doesn't renew.",
    },
  },

  forecast: {
    eyebrowHours: "{route} · in {hours} h",
    eyebrow: "{route}",
    eyebrowBare: "Your forecast",
    gradeBare: "Your forecast is ready.",
    sub: "See exactly when, and for how long.",
    yourFlight: "Your flight",
    departsIn: "Departs in {hours} h",
    confidence: {
      partly_confirmed: "Advanced forecast",
      confirmed: "Confirmed",
      global_outlook: "Global outlook (beta)",
    },
  },
} as const;

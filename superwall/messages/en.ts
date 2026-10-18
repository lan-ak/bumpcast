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
      live_activity_locked: "A countdown to every bump.",
      pilot_reports_locked: "See what pilots are feeling now.",
      live_status_locked: "Know about delays and gate changes first.",
      flight_limit_reached: "Keep every flight covered.",
      upgrade_from_settings: "Fly knowing what's coming.",
      fallback: "Fly knowing what's coming.",
    },

    featureTimeline: "Exactly when the bumps are, and for how long",
    featureUpdates: "Updates at 24, 6 and 2 hours, and when it's confirmed",
    featureLive: "A countdown to each bump on your Lock Screen, offline",
    featureStatus: "Live delays, gates and terminals for your flight",
    featurePilots: "Live pilot reports on the map",
    featureFlights: "As many upcoming flights as you like",

    yearly: "Yearly",
    monthly: "Monthly",
    perYear: "per year",
    perMonth: "per month",
    monthlyEquivalent: "{price}/month",
    cancelAnytime: "Cancel anytime",
    trialBadge: "{days} days free",

    ctaTrial: "Start {days}-day free trial",
    ctaSubscribe: "Subscribe",
    ctaPass: "Unlock this flight · {price}",
    ctaPassBare: "Unlock this flight",
    altPass: "Or unlock just this flight · {price}",
    altPassBare: "Or unlock just this flight",
    altTrial: "Or try Pro free for {days} days",
    altPro: "Or get Pro for every flight",

    legalTrial: "Free for {days} days, then {price}/year. Renews automatically. Cancel anytime in Settings.",
    legalAnnual: "{price}/year. Renews automatically. Cancel anytime in Settings.",
    legalMonthly: "{price}/month. Renews automatically. Cancel anytime in Settings.",
    legalBare: "Renews automatically. Cancel anytime in Settings.",
    legalPass: "The flight pass is a one-time purchase and doesn't renew.",
  },

  forecast: {
    eyebrowHours: "{route} · in {hours} h",
    eyebrow: "{route}",
    eyebrowBare: "Your forecast",
    gradeBare: "Your forecast is ready.",
    sub: "See exactly when, and for how long.",
  },
} as const;

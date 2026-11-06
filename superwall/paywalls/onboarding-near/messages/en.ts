import base from "../../onboarding/messages/en";

export default {
  ...base,
  // The timeline on both flight paywalls.
  timeline: {
    pro: "Pro",
    today: "Today",
    now: "Now",
    tracking: "We're tracking your flight",
    unlockWhen: "{day} · {time}",
    unlockWhenBare: "48 hours before you fly",
    firstForecast: "Your first forecast arrives",
    ready: "Your forecast is ready",
    pending: "Your forecast is on its way",
    untilLand: "Until you land",
    untilBoard: "Until you board",
    boardLine: "Exactly when the bumps come and how long they last, with updates if the weather changes",
    inTheAir: "In the air",
    airLine: "A countdown to each bump on your Lock Screen, even offline",
    proLineShort: "When the bumps come, updates, and a Lock Screen countdown",
    proLine: "When the bumps come and how long they last, updates if the weather changes, and a countdown on your Lock Screen",
  },
  // The offer for a flight leaving within 24 hours: Yearly or a pass for this flight.
  near: {
    sub: "You fly {day}.",
    lockHead: "When the bumps come",
    lockTitle: "Unlock to see",
    annualName: "Every flight",
    annualNote: "Yearly, {price}/month",
    bestValue: "Best value",
    passName: "This flight only",
    passNote: "One-time, doesn't renew",
    once: "once",
    ctaAnnual: "Subscribe · {price}/year",
    blocked: "The App Store couldn't start the purchase. Check Screen Time › iTunes & App Store Purchases and that you're signed in, then try again.",
  },
} as const;

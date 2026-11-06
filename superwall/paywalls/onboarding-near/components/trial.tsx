import { useEffect, useState } from "react";
import { useActions, useHaptics, useIntroductoryOffer, useProducts, usePurchase, useSuperwallSnapshot, useTranslation } from "superwall/hooks";
import { flight } from "../../onboarding/components/flight";
import { Ticket } from "../../onboarding/components/ticket";
import { HARD_FLIGHT_KEY, HARD_OPEN_KEY, saveableFlight } from "./near";
import { Timeline, type Step } from "./timeline";

const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
const PRIVACY_URL = "https://docs.google.com/document/d/1wgxMmBIa1OiTJesX83nBVIJl1c2EAz-TxvpMndDK7T0/preview";

/** "today" / "tonight" / "tomorrow", in the phone's time, for the subtitle. */
function flyDay(departure: Date, now = new Date()): string | undefined {
  const key = (d: Date) => d.toLocaleDateString("en-CA");
  const days = Math.round((Date.parse(key(departure)) - Date.parse(key(now))) / 86_400_000);
  if (days <= 0) return departure.getHours() >= 18 ? "tonight" : "today";
  return days === 1 ? "tomorrow" : undefined;
}

/**
 * The flight paywall for a flight leaving within 24 hours: their flight and what we know so far,
 * a timeline of the trial (everything today, the date the plan starts and what it costs), and one
 * plan, Yearly with a 3-day free trial, its yearly price as the biggest number on the page (App
 * Store guideline 3.1.2). Hard: no close button, so buying or restoring is the way on. A store that
 * says they've had a trial gets the same page as a plain subscription.
 */
export default function NearTrial() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const actions = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const { eligible } = useIntroductoryOffer();
  const opened = useSuperwallSnapshot().paywall !== undefined;
  const [restoreFailed, setRestoreFailed] = useState(false);
  const [blocked, setBlocked] = useState(false);
  const { added, forecast } = flight;
  const state = forecast?.state ?? "pending";

  // Which page of the test they reached, for reading it later, and the flight, so quitting the app
  // here brings them back to this page on the next launch (app/index.tsx). HARD_OPEN_KEY keeps
  // Forecast moments from opening over that relaunch (see near.ts).
  const { setUserAttributes } = actions;
  useEffect(() => {
    if (opened && added) setUserAttributes({ onboarding_near_offer: "trial", [HARD_FLIGHT_KEY]: saveableFlight(added), [HARD_OPEN_KEY]: true });
  }, [opened, added, setUserAttributes]);

  const plan = getProduct("trial")?.variables;
  const days = Number(plan?.trialPeriodDays);
  const trialDays = eligible === true && Number.isFinite(days) && days > 0 ? days : 0;
  const ends = new Date(Date.now() + trialDays * 86_400_000).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });

  const title = state === "ready" ? (forecast?.gradeTitle ?? t("flight.titleReadyBare")) : t("flight.titlePending");
  const day = added && flyDay(added.departure);

  const steps: Step[] = [
    { key: "today", when: t("timeline.today"), line: trialDays ? t("near.todayTrial") : t("near.todayPaid"), done: true },
    { key: "land", when: t("timeline.untilLand"), line: t("near.untilLand"), done: true },
  ];
  if (trialDays) {
    steps.push({
      key: "ends",
      when: ends,
      line: plan?.price ? t("near.endLine", { price: plan.price }) : t("near.endLineBare"),
    });
  }

  const cta = trialDays
    ? t("near.cta", { days: trialDays })
    : plan?.price ? t("near.ctaIneligible", { price: plan.price }) : t("pro.ctaSubscribe");
  // The App Store refusing before its sheet even shows (a failure, or an "abandon" faster than anyone
  // can tap) is the phone blocking purchases: 4 of the 17 people who tapped buy in the week to Nov 4.
  // Say how to fix it, since this page has no other way on.
  const buy = async () => {
    haptics.light();
    setBlocked(false);
    const started = Date.now();
    const result = await purchase("trial");
    if (result.status === "failed" || (result.status === "abandoned" && Date.now() - started < 1500)) setBlocked(true);
  };

  const legal = trialDays && plan?.price
    ? t("pro.legalTrial", { days: trialDays, price: plan.price })
    : plan?.price
      ? t("pro.legalAnnual", { price: plan.price })
      : t("pro.legalBare");

  return (
    <main className="page plans fp near">
      <div className="plans-hero fp-hero">
        <div className="plans-bar fp-bar">
          <button
            type="button"
            className="link"
            onClick={async () => {
              haptics.light();
              const result = await actions.restore();
              if (result.status === "restored") {
                actions.close();
                return;
              }
              setRestoreFailed(true);
            }}
          >
            {t("plans.restore")}
          </button>
        </div>
        <div className="fp-heading">
          {added && <Ticket added={added} forecast={forecast} />}
          <p className="fp-eyebrow">{state === "ready" ? t("flight.eyebrowReady") : t("flight.eyebrow")}</p>
          <h1 className="fp-title">{title}</h1>
          {day && <p className="fp-sub secondary">{t("near.sub", { day })}</p>}
        </div>
        <svg className="plans-scene" viewBox="0 0 390 120" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
          <circle cx="268" cy="92" r="40" style={{ fill: "var(--sun)" }} />
          <rect x="0" y="92" width="390" height="40" style={{ fill: "var(--water-top)" }} />
          <path d="M64 92 C90 92 100 64 122 64 S153 92 178 92 L420 92" fill="none" style={{ stroke: "var(--brand-line)" }} strokeWidth="7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>

      <div className="plans-sheet">
        <Timeline steps={steps} />

        <div className="plan plan--on near-plan">
          {trialDays > 0 && <span className="plan-badge">{t("pro.trialBadge", { days: trialDays })}</span>}
          <span className="near-plan-name">
            <span className="plan-name">{t("pro.yearly")}</span>
            {plan?.monthlyPrice && <span className="secondary footnote">{t("near.perMonth", { price: plan.monthlyPrice })}</span>}
          </span>
          {plan?.price && (
            <span className="near-plan-price">
              <span className="plan-price">{plan.price}</span>
              <span className="secondary footnote">{t("pro.perYear")}</span>
            </span>
          )}
        </div>

        <button type="button" className="cta fp-cta" onClick={() => void buy()}>{cta}</button>

        <p className="secondary footnote legal">{blocked ? t("near.blocked") : restoreFailed ? t("plans.restoreFailed") : legal}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => actions.openUrl(TERMS_URL)}>{t("plans.terms")}</button>
          <button type="button" className="link" onClick={() => actions.openUrl(PRIVACY_URL)}>{t("plans.privacy")}</button>
        </div>
      </div>
    </main>
  );
}

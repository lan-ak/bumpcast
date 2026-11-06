import { useEffect, useState } from "react";
import { useActions, useHaptics, useProducts, usePurchase, useSuperwallSnapshot, useTranslation, useVariables } from "superwall/hooks";
import { LockedForecast } from "../../../components/locked-forecast";
import { passProduct } from "../../../components/pro/pass";
import { flight } from "../../onboarding/components/flight";
import { Ticket } from "../../onboarding/components/ticket";
import { HARD_FLIGHT_KEY, HARD_OPEN_KEY, resume, saveableFlight } from "./near";
import "./near.css";

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
 * The flight paywall for a flight leaving within 24 hours: their flight, its forecast blurred under
 * "Unlock to see" (coloured by its real grade, neutral while it's on its way), and two ways to see it: Yearly ($49.99, no trial, selected) or a pass for just
 * this flight. Hard: no close button, so buying or restoring is the way on.
 *
 * No pass when this launch resumed the page after a quit (app/index.tsx): the app learns which
 * flight a pass is for only from `add_flight`, which a resume skips, so the pass would charge and
 * unlock nothing.
 */
export default function NearOffer() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const actions = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const pass = passProduct(useVariables().device.appVersion);
  const opened = useSuperwallSnapshot().paywall !== undefined;
  const [choice, setChoice] = useState<"annual" | "pass">("annual");
  const [restoreFailed, setRestoreFailed] = useState(false);
  const [blocked, setBlocked] = useState(false);
  const { added, forecast } = flight;
  const state = forecast?.state ?? "pending";
  const canPass = !resume.active;

  // Which page of the test they reached, for reading it later, and the flight, so quitting the app
  // here brings them back to this page on the next launch (app/index.tsx). HARD_OPEN_KEY keeps
  // Forecast moments from opening over that relaunch (see near.ts).
  const { setUserAttributes } = actions;
  useEffect(() => {
    if (opened && added) setUserAttributes({ onboarding_near_offer: "annual_or_pass", [HARD_FLIGHT_KEY]: saveableFlight(added), [HARD_OPEN_KEY]: true });
  }, [opened, added, setUserAttributes]);

  const annual = getProduct("annual")?.variables;
  const passPrice = getProduct(pass)?.variables.price;
  const picked = canPass ? choice : "annual";

  const title = state === "ready" ? (forecast?.gradeTitle ?? t("flight.titleReadyBare")) : t("flight.titlePending");
  const day = added && flyDay(added.departure);

  const cta = picked === "pass"
    ? passPrice ? t("pro.ctaPass", { price: passPrice }) : t("pro.ctaPassBare")
    : annual?.price ? t("near.ctaAnnual", { price: annual.price }) : t("pro.ctaSubscribe");
  const legal = picked === "pass"
    ? t("pro.short.legalPass")
    : annual?.price ? t("pro.legalAnnual", { price: annual.price }) : t("pro.legalBare");

  const pick = (p: "annual" | "pass") => {
    haptics.selection();
    setChoice(p);
  };
  // The App Store refusing before its sheet even shows (a failure, or an "abandon" faster than anyone
  // can tap) is the phone blocking purchases: 4 of the 17 people who tapped buy in the week to Nov 4.
  // Say how to fix it, since this page has no other way on.
  const buy = async () => {
    haptics.light();
    setBlocked(false);
    const started = Date.now();
    const result = await purchase(picked === "pass" ? pass : "annual");
    if (result.status === "failed" || (result.status === "abandoned" && Date.now() - started < 1500)) setBlocked(true);
  };

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
        <LockedForecast head={t("near.lockHead")} title={t("near.lockTitle")} grade={forecast?.grade} />

        <div className="near-opts" role="radiogroup">
          <button type="button" role="radio" aria-checked={picked === "annual"} className={`near-opt${picked === "annual" ? " near-opt--on" : ""}`} onClick={() => pick("annual")}>
            <span className="near-radio" aria-hidden="true" />
            <span className="near-opt-name">
              <span>{t("near.annualName")}{canPass && <span className="near-tag">{t("near.bestValue")}</span>}</span>
              <span className="secondary footnote">{annual?.monthlyPrice ? t("near.annualNote", { price: annual.monthlyPrice }) : t("pro.yearly")}</span>
            </span>
            {annual?.price && (
              <span className="near-opt-price">
                <span>{annual.price}</span>
                <span className="secondary footnote">{t("pro.perYear")}</span>
              </span>
            )}
          </button>
          {canPass && (
            <button type="button" role="radio" aria-checked={picked === "pass"} className={`near-opt${picked === "pass" ? " near-opt--on" : ""}`} onClick={() => pick("pass")}>
              <span className="near-radio" aria-hidden="true" />
              <span className="near-opt-name">
                <span>{t("near.passName")}</span>
                <span className="secondary footnote">{t("near.passNote")}</span>
              </span>
              {passPrice && (
                <span className="near-opt-price">
                  <span>{passPrice}</span>
                  <span className="secondary footnote">{t("near.once")}</span>
                </span>
              )}
            </button>
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

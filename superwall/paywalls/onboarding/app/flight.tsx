import { useState, type ReactNode } from "react";
import { useActions, useHaptics, useIntroductoryOffer, useProducts, usePurchase, useTranslation } from "superwall/hooks";
import { AIRPORT_CITIES } from "@/components/pro/airports";
import { departureText, flight, unlockText, type AddedFlight, type FlightForecast } from "../components/flight";

const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
const PRIVACY_URL = "https://docs.google.com/document/d/1wgxMmBIa1OiTJesX83nBVIJl1c2EAz-TxvpMndDK7T0/preview";

const icon = (d: string): ReactNode => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

// What the pass buys: when and how long (never shown here), and updates until they board.
const FEATURES: { key: string; icon: ReactNode }[] = [
  { key: "featureTimeline", icon: icon("M4 20V10M10 20V4M16 20v-7M22 20H2") },
  { key: "featureUpdates", icon: icon("M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6") },
];

// What Pro covers, as on every Pro paywall, so the outlook never reads as US quality.
const COVERAGE: { key: string; icon: ReactNode }[] = [
  { key: "coverageUS", icon: icon("M4 12h16M12 4v16") },
  { key: "coverageGlobal", icon: icon("M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM2 12h20M12 2a15 15 0 0 1 0 20M12 2a15 15 0 0 0 0 20") },
];

function End({ code, align }: { code: string; align: "start" | "end" }) {
  const city = AIRPORT_CITIES[code];
  return (
    <div className={`tk-end tk-end--${align}`}>
      <span className="tk-code">{code}</span>
      {city && <span className="tk-city">{city}</span>}
    </div>
  );
}

function Ticket({ added, forecast }: { added: AddedFlight; forecast?: FlightForecast }) {
  const { t } = useTranslation();
  // No pill for an early forecast: "too early to predict" above a grade undercuts it.
  const pill = forecast?.state === "ready" && forecast.confidence && forecast.confidence !== "early"
    ? t(`forecast.confidence.${forecast.confidence}`)
    : undefined;
  return (
    <div className="tk">
      <p className="tk-top">{t("flight.departs", { time: departureText(added) })}</p>
      <div className="tk-row">
        <End code={added.origin} align="start" />
        <svg className="tk-path" viewBox="0 0 80 24" aria-hidden="true">
          <path d="M2 18 C22 18 28 6 40 6 S58 18 78 18" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="3 4" strokeLinecap="round" />
          <path d="M36 2.5 41.5 6 36 9.5 37 6z" fill="currentColor" />
        </svg>
        <End code={added.destination} align="end" />
      </div>
      {pill && (
        <div className="tk-pills">
          <span className="tk-pill">{pill}</span>
        </div>
      )}
    </div>
  );
}

/**
 * The hard paywall for people flying in the next 3 days: their flight, what we know so far (the
 * grade, when it's ready), and the pass for this flight. No close button: buying or restoring is
 * the way on. "More options" opens This flight, Yearly and Monthly as one choice.
 */
export default function FlightPaywall() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { close, restore, openUrl } = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const { eligible } = useIntroductoryOffer();
  const [choice, setChoice] = useState<"pass" | "annual" | "monthly">("pass");
  const [expanded, setExpanded] = useState(false);
  const [restoreFailed, setRestoreFailed] = useState(false);
  const { added, forecast } = flight;
  const state = forecast?.state ?? "pending";

  const annual = getProduct("annual")?.variables;
  const monthly = getProduct("monthly")?.variables;
  const passPrice = getProduct("pass")?.variables.price;
  const days = Number(annual?.trialPeriodDays);
  const trialDays = eligible === true && Number.isFinite(days) && days > 0 ? days : 0;

  const unlock = added && unlockText(added);
  const eyebrow = state === "ready" ? t("flight.eyebrowReady") : t("flight.eyebrow");
  const title =
    state === "ready"
      ? (forecast?.gradeTitle ?? t("flight.titleReadyBare"))
      : state === "too_early"
        ? t("flight.titleTooEarly")
        : t("flight.titlePending");
  // Ready: the ticket and the selling lines say it (as on the forecast-moment paywall).
  const subtitle =
    state === "ready"
      ? undefined
      : state === "too_early"
        ? unlock
          ? t("flight.subTooEarly", unlock)
          : t("flight.subTooEarlyBare")
        : t("flight.subPending");

  const passLegal = t("pro.legalPass");
  const legal = !expanded || choice === "pass"
    ? passLegal
    : choice === "annual"
      ? trialDays && annual?.price
        ? t("pro.legalTrial", { days: trialDays, price: annual.price })
        : annual?.price
          ? t("pro.legalAnnual", { price: annual.price })
          : t("pro.legalBare")
      : monthly?.price
        ? t("pro.legalMonthly", { price: monthly.price })
        : t("pro.legalBare");
  const passCta = passPrice ? t("pro.ctaPass", { price: passPrice }) : t("pro.ctaPassBare");
  const cta = choice === "pass" ? passCta : choice === "annual" && trialDays ? t("pro.ctaTrial", { days: trialDays }) : t("pro.ctaSubscribe");

  const buy = (product: "pass" | "annual" | "monthly") => {
    haptics.light();
    void purchase(product);
  };
  const pick = (p: "pass" | "annual" | "monthly") => {
    haptics.selection();
    setChoice(p);
  };

  return (
    <main className="page plans fp">
      <div className="plans-hero fp-hero">
        <div className="plans-bar fp-bar">
          <button
            type="button"
            className="link"
            onClick={async () => {
              haptics.light();
              const result = await restore();
              if (result.status === "restored") {
                close();
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
          <p className="fp-eyebrow">{eyebrow}</p>
          <h1 className="fp-title">{title}</h1>
          {subtitle && <p className="fp-sub secondary">{subtitle}</p>}
        </div>
        <svg className="plans-scene" viewBox="0 0 390 120" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
          <circle cx="268" cy="92" r="40" style={{ fill: "var(--sun)" }} />
          <rect x="0" y="92" width="390" height="40" style={{ fill: "var(--water-top)" }} />
          <path
            d="M64 92 C90 92 100 64 122 64 S153 92 178 92 L420 92"
            fill="none"
            style={{ stroke: "var(--brand-line)" }}
            strokeWidth="7"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>

      <div className="plans-sheet">
        {!expanded &&
          FEATURES.map((f) => (
            <div key={f.key} className="feature">
              <span className="feature-icon">{f.icon}</span>
              {t(`flight.${f.key}`)}
            </div>
          ))}
        {COVERAGE.map((f) => (
          <div key={f.key} className="feature feature--coverage">
            <span className="feature-icon">{f.icon}</span>
            {t(`pro.short.${f.key}`)}
          </div>
        ))}

        {expanded ? (
          <>
            <div className="plan-grid plan-grid--three" role="radiogroup">
              <button type="button" role="radio" aria-checked={choice === "pass"} className={`plan${choice === "pass" ? " plan--on" : ""}`} onClick={() => pick("pass")}>
                <span className="plan-name">{t("pro.thisFlight")}</span>
                {passPrice && <span className="plan-price">{passPrice}</span>}
                <span className="secondary footnote">{t("pro.oneTime")}</span>
                <span className="plan-note">{t("pro.noSubscription")}</span>
              </button>
              <button type="button" role="radio" aria-checked={choice === "annual"} className={`plan${choice === "annual" ? " plan--on" : ""}`} onClick={() => pick("annual")}>
                {trialDays > 0 && <span className="plan-badge">{t("pro.trialBadge", { days: trialDays })}</span>}
                <span className="plan-name">{t("pro.yearly")}</span>
                {annual?.price && <span className="plan-price">{annual.price}</span>}
                <span className="secondary footnote">{t("pro.perYear")}</span>
                {annual?.monthlyPrice && <span className="plan-note">{t("pro.monthlyEquivalent", { price: annual.monthlyPrice })}</span>}
              </button>
              <button type="button" role="radio" aria-checked={choice === "monthly"} className={`plan${choice === "monthly" ? " plan--on" : ""}`} onClick={() => pick("monthly")}>
                <span className="plan-name">{t("pro.monthly")}</span>
                {monthly?.price && <span className="plan-price">{monthly.price}</span>}
                <span className="secondary footnote">{t("pro.perMonth")}</span>
                <span className="plan-note">{t("pro.cancelAnytime")}</span>
              </button>
            </div>
            <button type="button" className="cta" onClick={() => buy(choice)}>{cta}</button>
          </>
        ) : (
          <>
            <button type="button" className="cta fp-cta" onClick={() => buy("pass")}>{passCta}</button>
            <button type="button" className="alt" onClick={() => { haptics.selection(); setExpanded(true); }}>
              {t("pro.moreOptions")}
            </button>
          </>
        )}

        <p className="secondary footnote legal">{restoreFailed ? t("plans.restoreFailed") : legal}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => openUrl(TERMS_URL)}>{t("plans.terms")}</button>
          <button type="button" className="link" onClick={() => openUrl(PRIVACY_URL)}>{t("plans.privacy")}</button>
        </div>
      </div>
    </main>
  );
}

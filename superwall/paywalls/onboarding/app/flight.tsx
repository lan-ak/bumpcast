import { useState, type ReactNode } from "react";
import { useActions, useHaptics, useIntroductoryOffer, useProducts, usePurchase, useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { flight, unlockText } from "../components/flight";
import { Ticket } from "../components/ticket";
import { variant } from "../components/variant";

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

/**
 * The hard paywall for people flying in the next 3 days: their flight, what we know so far (the
 * grade, when it's ready), and Pro: Yearly with the free trial, Monthly as the fallback. No close
 * button on `onboarding` (buying or restoring is the way on); `onboarding-soft` adds one, for the
 * hard-vs-soft test. Closing the App Store sheet offers the flight pass (`pass-offer`), once.
 */
export default function FlightPaywall() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { close, restore, openUrl } = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const { eligible } = useIntroductoryOffer();
  const router = useRouter();
  const [choice, setChoice] = useState<"annual" | "monthly">("annual");
  const [restoreFailed, setRestoreFailed] = useState(false);
  const { added, forecast } = flight;
  const state = forecast?.state ?? "pending";

  const annual = getProduct("annual")?.variables;
  const monthly = getProduct("monthly")?.variables;
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

  const legal =
    choice === "annual"
      ? trialDays && annual?.price
        ? t("pro.legalTrial", { days: trialDays, price: annual.price })
        : annual?.price
          ? t("pro.legalAnnual", { price: annual.price })
          : t("pro.legalBare")
      : monthly?.price
        ? t("pro.legalMonthly", { price: monthly.price })
        : t("pro.legalBare");
  const cta = choice === "annual" && trialDays ? t("pro.ctaTrial", { days: trialDays }) : t("pro.ctaSubscribe");

  const buy = async () => {
    haptics.light();
    const result = await purchase(choice);
    // Closed the App Store sheet: offer just this flight, once.
    if (result.status === "abandoned" && flight.added && !flight.passOffered) {
      flight.passOffered = true;
      router.push("pass-offer");
    }
  };
  const pick = (p: "annual" | "monthly") => {
    haptics.selection();
    setChoice(p);
  };

  return (
    <main className="page plans fp">
      <div className="plans-hero fp-hero">
        <div className={`plans-bar fp-bar${variant.soft ? " fp-bar--soft" : ""}`}>
          {variant.soft && (
            <button type="button" className="round-button" aria-label={t("plans.close")} onClick={() => { haptics.light(); close(); }}>
              {icon("M6 6l12 12M18 6 6 18")}
            </button>
          )}
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
        {FEATURES.map((f) => (
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

        <div className="plan-grid" role="radiogroup">
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
        <button type="button" className="cta" onClick={() => void buy()}>{cta}</button>

        <p className="secondary footnote legal">{restoreFailed ? t("plans.restoreFailed") : legal}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => openUrl(TERMS_URL)}>{t("plans.terms")}</button>
          <button type="button" className="link" onClick={() => openUrl(PRIVACY_URL)}>{t("plans.privacy")}</button>
        </div>
      </div>
    </main>
  );
}

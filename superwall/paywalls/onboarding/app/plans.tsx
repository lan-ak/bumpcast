import { useState, type ReactNode } from "react";
import {
  useActions,
  useHaptics,
  useIntroductoryOffer,
  useProducts,
  usePurchase,
  useTranslation,
  type ProductReference,
} from "superwall/hooks";
import { answers, type Help } from "../components/answers";

const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";

const icon = (d: string): ReactNode => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

// Pro features only (see Paywalls.swift): breathing and explainers are free, so they're not sold here.
const FEATURES: { key: string; icon: ReactNode; matches: Help[] }[] = [
  { key: "featureUpdates", icon: icon("M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6"), matches: ["when"] },
  { key: "featureTimeline", icon: icon("M4 20V10M10 20V4M16 20v-7M22 20H2"), matches: ["how-long"] },
  { key: "featureLive", icon: icon("M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2"), matches: ["when", "calm-down"] },
  { key: "featureFlights", icon: icon("M10.5 13.5 3 11l1.5-1.5 7.5 1 4-4.5a1.8 1.8 0 0 1 2.5 2.5L14 13l1 7.5-1.5 1.5-2.5-7.5-3 3V20l-1.5 1-1-3.5L2 16l1-1.5h2.5z"), matches: [] },
];

export default function Plans() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { close, restore, openUrl } = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const { eligible } = useIntroductoryOffer();
  const [plan, setPlan] = useState<ProductReference>("annual");
  const [restoreFailed, setRestoreFailed] = useState(false);

  const annual = getProduct("annual");
  const monthly = getProduct("monthly");
  const annualPrice = annual?.variables.price;
  const monthlyPrice = monthly?.variables.price;
  const annualPerMonth = annual?.variables.monthlyPrice;
  const days = Number(annual?.variables.trialPeriodDays);
  const trialDays = eligible === true && Number.isFinite(days) && days > 0 ? days : 0;

  const cta = plan === "annual" && trialDays ? t("plans.ctaTrial", { days: trialDays }) : t("plans.cta");
  const legal =
    plan === "annual"
      ? trialDays && annualPrice
        ? t("plans.legalTrial", { days: trialDays, price: annualPrice })
        : annualPrice
          ? t("plans.legalAnnual", { price: annualPrice })
          : t("plans.legalBare")
      : monthlyPrice
        ? t("plans.legalMonthly", { price: monthlyPrice })
        : t("plans.legalBare");

  const choose = (ref: ProductReference) => {
    haptics.selection();
    setPlan(ref);
  };

  return (
    <main className="page plans">
      <div className="plans-hero">
        <div className="plans-bar">
          <button type="button" className="round-button" aria-label={t("plans.close")} onClick={() => { haptics.light(); close(); }}>
            {icon("M6 6l12 12M18 6 6 18")}
          </button>
          <button
            type="button"
            className="link"
            onClick={async () => {
              haptics.light();
              const result = await restore();
              setRestoreFailed(result.status === "failed");
            }}
          >
            {t("plans.restore")}
          </button>
        </div>
        <h1 className="plans-title">{t("plans.title")}</h1>
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
          <div key={f.key} className={`feature${f.matches.some((m) => answers.help.includes(m)) ? " feature--match" : ""}`}>
            <span className="feature-icon">{f.icon}</span>
            {t(`plans.${f.key}`)}
          </div>
        ))}

        <div className="plan-grid" role="radiogroup">
          <button type="button" role="radio" aria-checked={plan === "annual"} className={`plan${plan === "annual" ? " plan--on" : ""}`} onClick={() => choose("annual")}>
            {trialDays > 0 && <span className="plan-badge">{t("plans.trialBadge", { days: trialDays })}</span>}
            <span className="plan-name">{t("plans.yearly")}</span>
            {annualPrice && <span className="plan-price">{annualPrice}</span>}
            <span className="secondary footnote">{t("plans.perYear")}</span>
            {annualPerMonth && <span className="plan-note">{t("plans.monthlyEquivalent", { price: annualPerMonth })}</span>}
          </button>
          <button type="button" role="radio" aria-checked={plan === "monthly"} className={`plan${plan === "monthly" ? " plan--on" : ""}`} onClick={() => choose("monthly")}>
            <span className="plan-name">{t("plans.monthly")}</span>
            {monthlyPrice && <span className="plan-price">{monthlyPrice}</span>}
            <span className="secondary footnote">{t("plans.perMonth")}</span>
            <span className="plan-note">{t("plans.cancelAnytime")}</span>
          </button>
        </div>

        <button
          type="button"
          className="cta"
          onClick={() => {
            haptics.light();
            void purchase(plan);
          }}
        >
          {cta}
        </button>
        <p className="secondary footnote legal">{restoreFailed ? t("plans.restoreFailed") : legal}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => openUrl(TERMS_URL)}>{t("plans.terms")}</button>
        </div>
      </div>
    </main>
  );
}


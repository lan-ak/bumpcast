import { useState, type ReactNode } from "react";
import {
  useActions,
  useHaptics,
  useIntroductoryOffer,
  useProducts,
  usePurchase,
  useTranslation,
} from "superwall/hooks";
import { usePlacementContext, type ProPlacement } from "./context";
import "./theme.css";

const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
const PRIVACY_URL = "https://docs.google.com/document/d/1wgxMmBIa1OiTJesX83nBVIJl1c2EAz-TxvpMndDK7T0/preview";

/**
 * Which offer is the button. The other is a quiet link under it. This is the A/B test between
 * pro-features and pro-features-pass-first. Without a flight there's no pass, so Pro always leads.
 */
export type Lead = "pro" | "pass";

const icon = (d: string): ReactNode => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

// Pro features only (Paywalls.swift), led by updates as the flight changes. Breathing, explainers
// and live flight status (gate, delays) are free, so they're not sold here.
const FEATURES: { key: string; icon: ReactNode; placement: ProPlacement }[] = [
  { key: "featureUpdates", icon: icon("M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6"), placement: "updates_locked" },
  { key: "featureTimeline", icon: icon("M4 20V10M10 20V4M16 20v-7M22 20H2"), placement: "timeline_locked" },
  { key: "featureLive", icon: icon("M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2"), placement: "live_activity_locked" },
  { key: "featurePilots", icon: icon("M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21zM12 12a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z"), placement: "pilot_reports_locked" },
  { key: "featureFlights", icon: icon("M10.5 13.5 3 11l1.5-1.5 7.5 1 4-4.5a1.8 1.8 0 0 1 2.5 2.5L14 13l1 7.5-1.5 1.5-2.5-7.5-3 3V20l-1.5 1-1-3.5L2 16l1-1.5h2.5z"), placement: "flight_limit_reached" },
];

// What Pro covers, always shown together so the outlook never reads as US quality.
const COVERAGE: { key: string; icon: ReactNode }[] = [
  { key: "coverageUS", icon: icon("M4 12h16M12 4v16") },
  { key: "coverageGlobal", icon: icon("M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM2 12h20M12 2a15 15 0 0 1 0 20M12 2a15 15 0 0 0 0 20") },
];

/** The sunrise from the onboarding Plans page. */
function Scene() {
  return (
    <svg className="pw-scene" viewBox="0 0 390 120" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
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
  );
}

/**
 * Every Pro paywall: the dawn sky with a headline, and a sheet with two benefits and the offer.
 * Pass `eyebrow`/`title`/`subtitle` to override the placement's headline (the soft paywall does).
 */
export function ProPaywall({
  lead,
  eyebrow,
  title,
  subtitle,
  highlight,
}: {
  lead: Lead;
  eyebrow?: string;
  title?: string;
  subtitle?: string;
  /** The feature to list first, when it isn't the placement's own. */
  highlight?: ProPlacement;
}) {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { close, restore, openUrl } = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const { eligible } = useIntroductoryOffer();
  const { placement, flight } = usePlacementContext();
  const [plan, setPlan] = useState<"annual" | "monthly">("annual");
  const [restoreFailed, setRestoreFailed] = useState(false);

  const canPass = flight.flightID !== undefined;
  const passLeads = lead === "pass" && canPass;

  const annual = getProduct("annual")?.variables;
  const monthly = getProduct("monthly")?.variables;
  const passPrice = getProduct("pass")?.variables.price;
  const days = Number(annual?.trialPeriodDays);
  const trialDays = eligible === true && Number.isFinite(days) && days > 0 ? days : 0;

  const first = highlight ?? placement;
  const features = [...FEATURES]
    .sort((a, b) => Number(b.placement === first) - Number(a.placement === first))
    .slice(0, 2);

  const annualLegal =
    trialDays && annual?.price
      ? t("pro.legalTrial", { days: trialDays, price: annual.price })
      : annual?.price
        ? t("pro.legalAnnual", { price: annual.price })
        : t("pro.legalBare");
  const subscriptionLegal =
    plan === "annual" || passLeads
      ? annualLegal
      : monthly?.price
        ? t("pro.legalMonthly", { price: monthly.price })
        : t("pro.legalBare");
  const legal = !canPass
    ? subscriptionLegal
    : passLeads
      ? `${t("pro.legalPass")} ${subscriptionLegal}`
      : `${subscriptionLegal} ${t("pro.legalPass")}`;

  const buy = (product: "annual" | "monthly" | "pass") => {
    haptics.light();
    void purchase(product);
  };
  const choose = (p: "annual" | "monthly") => {
    haptics.selection();
    setPlan(p);
  };

  return (
    <main className="pw">
      <div className="pw-hero">
        <div className="pw-bar">
          <button type="button" className="round-button" aria-label={t("pro.close")} onClick={() => { haptics.light(); close(); }}>
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
            {t("pro.restore")}
          </button>
        </div>
        <div className="pw-heading">
          {eyebrow && <p className="pw-eyebrow">{eyebrow}</p>}
          <h1 className="pw-title">{title ?? t(`pro.title.${placement ?? "fallback"}`)}</h1>
          {subtitle && <p className="pw-sub">{subtitle}</p>}
        </div>
        <Scene />
      </div>

      <div className="pw-sheet">
        {features.map((f) => (
          <div key={f.key} className="feature">
            <span className="feature-icon">{f.icon}</span>
            {t(`pro.${f.key}`)}
          </div>
        ))}
        {COVERAGE.map((f) => (
          <div key={f.key} className="feature feature--coverage">
            <span className="feature-icon">{f.icon}</span>
            {t(`pro.${f.key}`)}
          </div>
        ))}

        {passLeads ? (
          <>
            <button type="button" className="cta cta--spaced" onClick={() => buy("pass")}>
              {passPrice ? t("pro.ctaPass", { price: passPrice }) : t("pro.ctaPassBare")}
            </button>
            <button type="button" className="alt" onClick={() => buy("annual")}>
              {trialDays ? t("pro.altTrial", { days: trialDays }) : t("pro.altPro")}
            </button>
          </>
        ) : (
          <>
            <div className="plan-grid" role="radiogroup">
              <button type="button" role="radio" aria-checked={plan === "annual"} className={`plan${plan === "annual" ? " plan--on" : ""}`} onClick={() => choose("annual")}>
                {trialDays > 0 && <span className="plan-badge">{t("pro.trialBadge", { days: trialDays })}</span>}
                <span className="plan-name">{t("pro.yearly")}</span>
                {annual?.price && <span className="plan-price">{annual.price}</span>}
                <span className="secondary footnote">{t("pro.perYear")}</span>
                {annual?.monthlyPrice && <span className="plan-note">{t("pro.monthlyEquivalent", { price: annual.monthlyPrice })}</span>}
              </button>
              <button type="button" role="radio" aria-checked={plan === "monthly"} className={`plan${plan === "monthly" ? " plan--on" : ""}`} onClick={() => choose("monthly")}>
                <span className="plan-name">{t("pro.monthly")}</span>
                {monthly?.price && <span className="plan-price">{monthly.price}</span>}
                <span className="secondary footnote">{t("pro.perMonth")}</span>
                <span className="plan-note">{t("pro.cancelAnytime")}</span>
              </button>
            </div>
            <button type="button" className="cta" onClick={() => buy(plan)}>
              {plan === "annual" && trialDays ? t("pro.ctaTrial", { days: trialDays }) : t("pro.ctaSubscribe")}
            </button>
            {canPass && (
              <button type="button" className="alt" onClick={() => buy("pass")}>
                {passPrice ? t("pro.altPass", { price: passPrice }) : t("pro.altPassBare")}
              </button>
            )}
          </>
        )}

        <p className="secondary footnote legal">{restoreFailed ? t("pro.restoreFailed") : legal}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => openUrl(TERMS_URL)}>{t("pro.terms")}</button>
          <button type="button" className="link" onClick={() => openUrl(PRIVACY_URL)}>{t("pro.privacy")}</button>
        </div>
      </div>
    </main>
  );
}

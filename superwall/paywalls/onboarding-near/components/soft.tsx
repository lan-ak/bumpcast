import { useEffect, useState } from "react";
import { useActions, useHaptics, useProducts, usePurchase, useSuperwallSnapshot, useTranslation } from "superwall/hooks";
import { flight, unlockText } from "../../onboarding/components/flight";
import { savePercent } from "../../onboarding/components/savings";
import { Ticket } from "../../onboarding/components/ticket";
import { Timeline, type Step } from "./timeline";

const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
const PRIVACY_URL = "https://docs.google.com/document/d/1wgxMmBIa1OiTJesX83nBVIJl1c2EAz-TxvpMndDK7T0/preview";

const close = (d: string) => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

/**
 * The soft flight paywall (any flight not leaving within 24 hours), laid out like the near-flier
 * trial: their flight, then a timeline of what happens next for it, free steps filled and what Pro
 * adds tagged, then Yearly ($49.99, no trial, badged with its saving) and Monthly. Closable.
 */
export default function SoftTimeline() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const actions = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const [choice, setChoice] = useState<"annual" | "monthly">("annual");
  const [restoreFailed, setRestoreFailed] = useState(false);
  const { added, forecast } = flight;
  const state = forecast?.state ?? "pending";
  const opened = useSuperwallSnapshot().paywall !== undefined;

  // Which page of the test they reached, for reading it later (the near offer sets "annual_or_pass").
  const { setUserAttributes } = actions;
  useEffect(() => {
    if (opened) setUserAttributes({ onboarding_near_offer: "timeline" });
  }, [opened, setUserAttributes]);

  const annual = getProduct("annual")?.variables;
  const monthly = getProduct("monthly")?.variables;
  const save = savePercent(annual, monthly);
  const unlock = added && unlockText(added);
  // "tomorrow · 9:40 am" starts a line here, so it takes a capital.
  const cap = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);

  const title =
    state === "ready"
      ? (forecast?.gradeTitle ?? t("flight.titleReadyBare"))
      : state === "too_early"
        ? t("flight.titleTooEarly")
        : t("flight.titlePending");

  // Free steps first (filled once true), then what Pro adds. A flight too early to forecast has
  // one more free step (when the forecast arrives), so Pro is one step there.
  const steps: Step[] =
    state === "too_early"
      ? [
          { key: "tracking", when: t("timeline.today"), line: t("timeline.tracking"), done: true },
          {
            key: "forecast",
            when: unlock ? cap(t("timeline.unlockWhen", unlock)) : t("timeline.unlockWhenBare"),
            line: t("timeline.firstForecast"),
          },
          { key: "pro", when: t("timeline.untilLand"), line: t("timeline.proLine"), pro: true },
          { key: "pro-short", when: t("timeline.untilLand"), line: t("timeline.proLineShort"), pro: true },
        ]
      : [
          { key: "now", when: t("timeline.now"), line: state === "ready" ? t("timeline.ready") : t("timeline.pending"), done: state === "ready" },
          { key: "board", when: t("timeline.untilBoard"), line: t("timeline.boardLine"), pro: true },
          { key: "air", when: t("timeline.inTheAir"), line: t("timeline.airLine"), pro: true },
          // Short screens (iPhone SE) show this one step instead of the two above (near.css).
          { key: "pro-short", when: t("timeline.untilLand"), line: t("timeline.proLineShort"), pro: true },
        ];

  const legal =
    choice === "annual"
      ? annual?.price ? t("pro.legalAnnual", { price: annual.price }) : t("pro.legalBare")
      : monthly?.price ? t("pro.legalMonthly", { price: monthly.price }) : t("pro.legalBare");
  const pick = (p: "annual" | "monthly") => {
    haptics.selection();
    setChoice(p);
  };

  return (
    <main className="page plans fp near">
      <div className="plans-hero fp-hero">
        <div className="plans-bar fp-bar fp-bar--soft">
          <button type="button" className="round-button" aria-label={t("plans.close")} onClick={() => { haptics.light(); actions.close(); }}>
            {close("M6 6l12 12M18 6 6 18")}
          </button>
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
        </div>
        <svg className="plans-scene" viewBox="0 0 390 120" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
          <circle cx="268" cy="92" r="40" style={{ fill: "var(--sun)" }} />
          <rect x="0" y="92" width="390" height="40" style={{ fill: "var(--water-top)" }} />
          <path d="M64 92 C90 92 100 64 122 64 S153 92 178 92 L420 92" fill="none" style={{ stroke: "var(--brand-line)" }} strokeWidth="7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>

      <div className="plans-sheet">
        <Timeline steps={steps} />

        <div className="plan-grid near-grid" role="radiogroup">
          <button type="button" role="radio" aria-checked={choice === "annual"} className={`plan${choice === "annual" ? " plan--on" : ""}`} onClick={() => pick("annual")}>
            {save > 0 && <span className="plan-badge">{t("flight.save", { percent: save })}</span>}
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
        <button type="button" className="cta fp-cta" onClick={() => { haptics.light(); void purchase(choice); }}>{t("pro.ctaSubscribe")}</button>

        <p className="secondary footnote legal">{restoreFailed ? t("plans.restoreFailed") : legal}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => actions.openUrl(TERMS_URL)}>{t("plans.terms")}</button>
          <button type="button" className="link" onClick={() => actions.openUrl(PRIVACY_URL)}>{t("plans.privacy")}</button>
        </div>
      </div>
    </main>
  );
}

import { useState, type ReactNode } from "react";
import { useActions, useHaptics, useProducts, usePurchase, useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { flight } from "../components/flight";
import { Ticket } from "../components/ticket";
import { variant } from "../components/variant";

const TERMS_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
const PRIVACY_URL = "https://docs.google.com/document/d/1wgxMmBIa1OiTJesX83nBVIJl1c2EAz-TxvpMndDK7T0/preview";

const icon = (d: string): ReactNode => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d={d} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

const FEATURES: { key: string; icon: ReactNode }[] = [
  { key: "featureTimeline", icon: icon("M4 20V10M10 20V4M16 20v-7M22 20H2") },
  { key: "featureUpdates", icon: icon("M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6") },
];

/**
 * After someone closes the App Store sheet on the flight paywall: just this flight, one payment,
 * no subscription. The app links a pass bought in the flow to the flight added in it. "Back to
 * plans" returns to Yearly and Monthly. Closable only on `onboarding-soft`, as the flight paywall.
 */
export default function PassOffer() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const router = useRouter();
  const { close, openUrl } = useActions();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const [buying, setBuying] = useState(false);
  const { added, forecast } = flight;
  const price = getProduct("pass")?.variables.price;
  const route = added ? `${added.origin} → ${added.destination}` : undefined;

  const buy = async () => {
    if (buying) return;
    haptics.light();
    setBuying(true);
    await purchase("pass");
    setBuying(false);
  };

  return (
    <main className="page plans fp">
      <div className="plans-hero fp-hero">
        {variant.soft && (
          <div className="plans-bar fp-bar fp-bar--soft">
            <button type="button" className="round-button" aria-label={t("plans.close")} onClick={() => { haptics.light(); close(); }}>
              {icon("M6 6l12 12M18 6 6 18")}
            </button>
          </div>
        )}
        <div className="fp-heading">
          {added && <Ticket added={added} forecast={forecast} />}
          <p className="fp-eyebrow">{t("passOffer.eyebrow")}</p>
          <h1 className="fp-title">{route ? t("passOffer.title", { route }) : t("passOffer.titleBare")}</h1>
          <p className="fp-sub secondary">{price ? t("passOffer.sub", { price }) : t("passOffer.subBare")}</p>
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
        <button type="button" className="cta fp-cta" onClick={() => void buy()}>
          {price ? t("pro.ctaPass", { price }) : t("pro.ctaPassBare")}
        </button>
        <button type="button" className="alt" onClick={() => { haptics.light(); router.back(); }}>
          {t("passOffer.back")}
        </button>
        <p className="secondary footnote legal">{t("passOffer.legal")}</p>
        <div className="legal-links">
          <button type="button" className="link" onClick={() => openUrl(TERMS_URL)}>{t("plans.terms")}</button>
          <button type="button" className="link" onClick={() => openUrl(PRIVACY_URL)}>{t("plans.privacy")}</button>
        </div>
      </div>
    </main>
  );
}

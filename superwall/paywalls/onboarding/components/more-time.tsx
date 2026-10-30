import { useEffect, useState } from "react";
import { useHaptics, useIntroductoryOffer, useProducts, usePurchase, useTranslation } from "superwall/hooks";

/** Offered at most once per flow, from whichever page the yearly plan was abandoned on. */
const offer = { shown: false };

/**
 * After someone closes the App Store sheet on the yearly plan (3-day trial): a sheet that slides
 * up with the same plan and a 7-day trial (`annual7`). Only for people the store says can still
 * get a trial, and only once per flow.
 */
export function useMoreTime() {
  const { getProduct } = useProducts();
  const { eligible } = useIntroductoryOffer();
  const [open, setOpen] = useState(false);
  const days = Number(getProduct("annual7")?.variables.trialPeriodDays);
  const available = eligible === true && Number.isFinite(days) && days > 0;

  /** Opens the sheet if it can; false means it didn't, so the page can do what it did before. */
  const show = () => {
    if (!available || offer.shown) return false;
    offer.shown = true;
    setOpen(true);
    return true;
  };
  return { open, show, hide: () => setOpen(false) };
}

/**
 * The "Need more time?" sheet. `onDecline` runs when they turn it down (No thanks, or closing the
 * App Store sheet again); a completed purchase dismisses the paywall as any other does.
 */
export function MoreTimeSheet({ open, onDecline }: { open: boolean; onDecline: () => void }) {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { getProduct } = useProducts();
  const { purchase } = usePurchase();
  const [shown, setShown] = useState(false);
  const [buying, setBuying] = useState(false);

  const product = getProduct("annual7")?.variables;
  const days = Number(product?.trialPeriodDays);
  const trialDays = Number.isFinite(days) && days > 0 ? days : 7;
  const price = product?.price;

  // Mount off screen, then slide up on the next frame.
  useEffect(() => {
    if (!open) {
      setShown(false);
      return;
    }
    const frame = requestAnimationFrame(() => requestAnimationFrame(() => setShown(true)));
    return () => cancelAnimationFrame(frame);
  }, [open]);

  if (!open) return null;

  const decline = () => {
    setShown(false);
    setTimeout(onDecline, 320);
  };

  const buy = async () => {
    if (buying) return;
    haptics.light();
    setBuying(true);
    const result = await purchase("annual7");
    setBuying(false);
    if (result.status !== "completed") decline();
  };

  return (
    <div className={`mt${shown ? " mt--shown" : ""}`} role="dialog" aria-modal="true" aria-labelledby="mt-title">
      <button type="button" className="mt-scrim" aria-label={t("moreTime.noThanks")} tabIndex={-1} onClick={() => { haptics.light(); decline(); }} />
      <div className="mt-sheet">
        <span className="mt-grabber" aria-hidden="true" />
        <h2 id="mt-title" className="mt-title">{t("moreTime.title")}</h2>
        <p className="secondary mt-body">
          {price ? t("moreTime.body", { days: trialDays, price }) : t("moreTime.bodyBare", { days: trialDays })}
        </p>
        <button type="button" className="cta" onClick={() => void buy()}>
          {t("plans.ctaTrial", { days: trialDays })}
        </button>
        <button type="button" className="text-button" onClick={() => { haptics.light(); decline(); }}>
          {t("moreTime.noThanks")}
        </button>
        <p className="secondary footnote legal">
          {price ? t("plans.legalTrial", { days: trialDays, price }) : t("plans.legalBare")}
        </p>
      </div>
    </div>
  );
}

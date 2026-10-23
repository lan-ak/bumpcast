import { useState } from "react";
import { useActions, useHaptics, useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { flight, parseFlight } from "../components/flight";
import { useNext } from "../components/next";
import { Page, PrimaryButton } from "../components/ui";

/**
 * For people flying in the next 3 days: the app's own Add flight opens over the flow (the
 * `add_flight` callback), and the flow carries on to that flight's forecast. Cancelling there
 * leaves them here, with the plans one tap away. If it can't open at all (an app version without
 * the callback, or the sheet couldn't present), they go on to the plans.
 */
export default function Find() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const router = useRouter();
  const { requestCallback } = useActions();
  const later = useNext("plans");
  const [adding, setAdding] = useState(false);

  const add = async () => {
    if (adding) return;
    setAdding(true);
    const result = await requestCallback("add_flight");
    setAdding(false);
    const added = result.status === "success" ? parseFlight(result.data) : undefined;
    if (!added) {
      if (result.data?.reason !== "cancelled") later();
      return;
    }
    haptics.success();
    flight.added = added;
    flight.forecast = undefined;
    router.push("checking", { transition: "fade" });
  };

  return (
    <Page
      footer={
        <>
          <PrimaryButton onPress={add} dimmed={adding}>{t("find.cta")}</PrimaryButton>
          <button type="button" className="text-button" onClick={() => { haptics.light(); later(); }}>
            {t("find.later")}
          </button>
        </>
      }
    >
      <div className="page-body" style={{ justifyContent: "center" }}>
        <p className="eyebrow">{t("find.eyebrow")}</p>
        <h1>{t("find.title")}</h1>
        <p className="secondary">{t("find.body")}</p>
      </div>
    </Page>
  );
}

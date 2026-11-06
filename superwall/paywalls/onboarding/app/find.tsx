import { useState } from "react";
import { useActions, useHaptics, useTranslation } from "superwall/hooks";
import { fliesSoon } from "../components/answers";
import { flight, parseFlight } from "../components/flight";
import { useNext } from "../components/next";
import { Page, PrimaryButton } from "../components/ui";

/**
 * For everyone, whenever they fly: the app's own Add flight opens over the flow (the `add_flight`
 * callback), then the notifications ask for that flight, then its forecast. Cancelling there
 * leaves them here, with "later" one tap away. If it can't open at all (an app version without
 * the callback, or the sheet couldn't present), they go on as if they'd tapped later.
 */
export default function Find() {
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { requestCallback } = useActions();
  const toNotifications = useNext("notifications");
  const soon = fliesSoon();
  const [adding, setAdding] = useState(false);

  const add = async () => {
    if (adding) return;
    setAdding(true);
    const result = await requestCallback("add_flight");
    setAdding(false);
    const added = result.status === "success" ? parseFlight(result.data) : undefined;
    if (!added) {
      if (result.data?.reason !== "cancelled") toNotifications();
      return;
    }
    haptics.success();
    flight.added = added;
    flight.forecast = undefined;
    toNotifications();
  };

  return (
    <Page
      footer={
        <>
          <PrimaryButton onPress={add} dimmed={adding}>{t("find.cta")}</PrimaryButton>
          <button type="button" className="text-button" onClick={() => { haptics.light(); toNotifications(); }}>
            {t("find.later")}
          </button>
        </>
      }
    >
      <div className="page-body" style={{ justifyContent: "center" }}>
        <p className="eyebrow">{t("find.eyebrow")}</p>
        <h1>{soon ? t("find.title") : t("find.titleLater")}</h1>
        <p className="secondary">{soon ? t("find.body") : t("find.bodyLater")}</p>
      </div>
    </Page>
  );
}

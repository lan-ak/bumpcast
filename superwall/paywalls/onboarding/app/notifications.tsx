import { useState } from "react";
import { useActions, useDevice, useHaptics, useTranslation } from "superwall/hooks";
import { AppIcon } from "../components/art";
import { canAddFlight, fliesSoon } from "../components/answers";
import { useNext } from "../components/next";
import { Page, PrimaryButton } from "../components/ui";

export default function Notifications() {
  // Flying soon, on an app that can add the flight from here: add it next. Everyone else: the plans.
  const { appVersion } = useDevice();
  const toPlans = useNext("plans");
  const toFind = useNext("find");
  const next = () => (fliesSoon() && canAddFlight(appVersion) ? toFind : toPlans)();
  const { t } = useTranslation();
  const haptics = useHaptics();
  const { requestPermission, setUserAttributes } = useActions();
  const [asking, setAsking] = useState(false);

  const allow = async () => {
    if (asking) return;
    setAsking(true);
    const status = await requestPermission("notification");
    setUserAttributes({ notifications_prompt: status });
    setAsking(false);
    next();
  };

  const later = () => {
    haptics.light();
    setUserAttributes({ notifications_prompt: "not-now" });
    next();
  };

  return (
    <Page
      footer={
        <>
          <PrimaryButton onPress={allow}>{t("notifications.allow")}</PrimaryButton>
          <button type="button" className="text-button" onClick={later}>{t("notifications.later")}</button>
        </>
      }
    >
      <div className="page-body" style={{ justifyContent: "center", gap: 40 }}>
        <div className="card push">
          <AppIcon size={38} />
          <div className="push-text">
            <div className="push-head">
              <b>{t("notifications.app")}</b>
              <span className="secondary footnote">{t("notifications.now")}</span>
            </div>
            {t("notifications.pushTitle")}
            <div className="secondary">{t("notifications.pushBody")}</div>
          </div>
        </div>
        <div>
          <h1>{t("notifications.title")}</h1>
          <p className="secondary">{t("notifications.body")}</p>
        </div>
      </div>
    </Page>
  );
}

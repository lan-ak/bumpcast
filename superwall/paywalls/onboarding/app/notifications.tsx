import { useState } from "react";
import { useActions, useHaptics, useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { AppIcon } from "../components/art";
import { Page, PrimaryButton } from "../components/ui";

export default function Notifications() {
  const router = useRouter();
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
    router.push("plans");
  };

  const later = () => {
    haptics.light();
    setUserAttributes({ notifications_prompt: "not-now" });
    router.push("plans");
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

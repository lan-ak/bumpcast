import { useTranslation } from "superwall/hooks";
import { AppIcon } from "../components/art";
import { useNext } from "../components/next";
import { Page, PrimaryButton } from "../components/ui";

export default function Welcome() {
  const next = useNext("feeling");
  const { t } = useTranslation();
  return (
    <Page className="page--bare" footer={<PrimaryButton onPress={next}>{t("welcome.cta")}</PrimaryButton>}>
      <div className="brand-row">
        <AppIcon size={34} />
        <span className="brand-name">{t("chrome.brand")}</span>
      </div>
      <div className="welcome-title">
        <h1>{t("welcome.title")}</h1>
        <p className="secondary">{t("welcome.subtitle")}</p>
      </div>
    </Page>
  );
}

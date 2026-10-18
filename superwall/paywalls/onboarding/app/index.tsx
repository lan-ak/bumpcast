import { useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { AppIcon } from "../components/art";
import { Page, PrimaryButton } from "../components/ui";

export default function Welcome() {
  const router = useRouter();
  const { t } = useTranslation();
  return (
    <Page className="page--bare" footer={<PrimaryButton onPress={() => router.push("feeling")}>{t("welcome.cta")}</PrimaryButton>}>
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

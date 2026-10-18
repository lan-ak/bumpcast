import { useEffect, useState } from "react";
import { useTranslation } from "superwall/hooks";
import { useIsFocused, useRouter } from "superwall/navigation";
import { answers } from "../components/answers";
import { Glass } from "../components/art";
import { Page, PrimaryButton } from "../components/ui";

export default function Reassure() {
  const router = useRouter();
  const { t } = useTranslation();
  const focused = useIsFocused();
  const [drawn, setDrawn] = useState(false);
  useEffect(() => {
    if (focused) setDrawn(true);
  }, [focused]);

  const calm = answers.feeling === "calm";
  return (
    <Page className="" footer={<PrimaryButton onPress={() => router.push("how")}>{t("reassure.cta")}</PrimaryButton>}>
      <div className="page-body spread">
        <div>
          <h1>{t(calm ? "reassure.titleCalm" : "reassure.titleAnxious")}</h1>
          <p className="secondary">{t("reassure.body")}</p>
        </div>
        <div className="card">
          <div className="flight-head">
            <div>
              <p className="eyebrow" style={{ marginBottom: 6 }}>{t("reassure.cardLabel")}</p>
              <div className="route">{t("reassure.route")}</div>
            </div>
            <Glass severity="light" size={44} />
          </div>
          <div className="grade">{t("reassure.grade")}</div>
          <svg viewBox="0 0 250 44" width="100%" height="48" aria-hidden="true">
            <rect x="62" y="0" width="34" height="44" rx="3" fill="#C99A2E" fillOpacity={0.25} />
            <rect x="168" y="0" width="22" height="44" rx="3" fill="#C99A2E" fillOpacity={0.25} />
            <path
              className={`wave-path${drawn ? " wave-path--drawn" : ""}`}
              d="M0,40 C30,40 50,36 62,35 C70,33 74,18 79,18 S88,33 96,34 L168,35 C172,34 175,23 179,23 S186,34 190,35 C215,36 235,40 250,41"
            />
          </svg>
          <div className="axis">
            <span>{t("reassure.takeoff")}</span>
            <span className="axis-stretch"><span className="dot-chop" />{t("reassure.stretch")}</span>
            <span>{t("reassure.landing")}</span>
          </div>
        </div>
      </div>
    </Page>
  );
}

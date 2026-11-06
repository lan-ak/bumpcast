import { useState } from "react";
import { useActions, useDevice, useTranslation } from "superwall/hooks";
import { answers, canAddFlight, type Source } from "../components/answers";
import { useNext } from "../components/next";
import { Option, Page } from "../components/ui";

const OPTIONS: [Source, "appStore" | "social" | "friend" | "other"][] = [
  ["app-store", "appStore"],
  ["social", "social"],
  ["friend", "friend"],
  ["other", "other"],
];

export default function SourcePage() {
  // Everyone who can add their next flight from the flow does that next, whenever they fly: a saved
  // flight is what brings them back when its forecast is ready. 1.0 can't: notifications, then plans.
  const { appVersion } = useDevice();
  const toFind = useNext("find", 380);
  const toNotifications = useNext("notifications", 380);
  const next = canAddFlight(appVersion) ? toFind : toNotifications;
  const { t } = useTranslation();
  const { setUserAttributes } = useActions();
  const [selected, setSelected] = useState(answers.source);

  const choose = (value: Source) => {
    setSelected(value);
    answers.source = value;
    setUserAttributes({ source: value });
    next();
  };

  return (
    <Page>
      <p className="eyebrow">{t("source.eyebrow")}</p>
      <h1 className="lede">{t("source.question")}</h1>
      <div role="radiogroup">
        {OPTIONS.map(([value, key]) => (
          <Option key={value} selected={selected === value} onPress={() => choose(value)}>
            {t(`source.${key}`)}
          </Option>
        ))}
      </div>
    </Page>
  );
}

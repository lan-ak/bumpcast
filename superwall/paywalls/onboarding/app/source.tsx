import { useState } from "react";
import { useActions, useTranslation } from "superwall/hooks";
import { answers, type Source } from "../components/answers";
import { useNext } from "../components/next";
import { Option, Page } from "../components/ui";

const OPTIONS: [Source, "appStore" | "social" | "friend" | "other"][] = [
  ["app-store", "appStore"],
  ["social", "social"],
  ["friend", "friend"],
  ["other", "other"],
];

export default function SourcePage() {
  const next = useNext("notifications", 380);
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

import { useState } from "react";
import { useActions, useTranslation } from "superwall/hooks";
import { answers, type Frequency } from "../components/answers";
import { useNext } from "../components/next";
import { Option, Page } from "../components/ui";

const OPTIONS: [Frequency, "yearly" | "few" | "monthly"][] = [
  ["yearly-or-less", "yearly"],
  ["few-a-year", "few"],
  ["monthly-plus", "monthly"],
];

export default function FrequencyPage() {
  const next = useNext("when", 380);
  const { t } = useTranslation();
  const { setUserAttributes } = useActions();
  const [selected, setSelected] = useState(answers.frequency);

  const choose = (value: Frequency) => {
    setSelected(value);
    answers.frequency = value;
    setUserAttributes({ fly_frequency: value });
    next();
  };

  return (
    <Page>
      <h1 className="lede">{t("frequency.question")}</h1>
      <div role="radiogroup">
        {OPTIONS.map(([value, key]) => (
          <Option key={value} selected={selected === value} onPress={() => choose(value)}>
            {t(`frequency.${key}`)}
          </Option>
        ))}
      </div>
    </Page>
  );
}

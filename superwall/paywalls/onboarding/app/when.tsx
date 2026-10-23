import { useState } from "react";
import { useActions, useTranslation } from "superwall/hooks";
import { answers, type NextFlight } from "../components/answers";
import { useNext } from "../components/next";
import { Option, Page } from "../components/ui";

const OPTIONS: [NextFlight, "day" | "days" | "week" | "later"][] = [
  ["24h", "day"],
  ["3d", "days"],
  ["week", "week"],
  ["later", "later"],
];

export default function WhenPage() {
  const next = useNext("source", 380);
  const { t } = useTranslation();
  const { setUserAttributes } = useActions();
  const [selected, setSelected] = useState(answers.nextFlight);

  const choose = (value: NextFlight) => {
    setSelected(value);
    answers.nextFlight = value;
    setUserAttributes({ next_flight_window: value });
    next();
  };

  return (
    <Page>
      <h1 className="lede">{t("when.question")}</h1>
      <div role="radiogroup">
        {OPTIONS.map(([value, key]) => (
          <Option key={value} selected={selected === value} onPress={() => choose(value)}>
            {t(`when.${key}`)}
          </Option>
        ))}
      </div>
    </Page>
  );
}

import { useState } from "react";
import { useActions, useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { answers, type Feeling } from "../components/answers";
import { Option, Page } from "../components/ui";

const OPTIONS: [Feeling, "calm" | "uneasy" | "nervous" | "anxious"][] = [
  ["calm", "calm"],
  ["a-little-uneasy", "uneasy"],
  ["nervous", "nervous"],
  ["very-anxious", "anxious"],
];

export default function FeelingPage() {
  const router = useRouter();
  const { t } = useTranslation();
  const { setUserAttributes } = useActions();
  const [selected, setSelected] = useState(answers.feeling);

  const choose = (value: Feeling) => {
    setSelected(value);
    answers.feeling = value;
    setUserAttributes({ fly_feeling: value });
    setTimeout(() => router.push("reassure"), 380);
  };

  return (
    <Page>
      <h1 className="lede">{t("feeling.question")}</h1>
      <div role="radiogroup">
        {OPTIONS.map(([value, key]) => (
          <Option key={value} selected={selected === value} onPress={() => choose(value)}>
            {t(`feeling.${key}`)}
          </Option>
        ))}
      </div>
    </Page>
  );
}

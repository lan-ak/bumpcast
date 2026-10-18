import { useState } from "react";
import { useActions, useTranslation } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import { answers, type Help } from "../components/answers";
import { Option, Page, PrimaryButton } from "../components/ui";

const OPTIONS: [Help, "when" | "howLong" | "normal" | "calmDown" | "delays"][] = [
  ["when", "when"],
  ["how-long", "howLong"],
  ["normal", "normal"],
  ["calm-down", "calmDown"],
  ["delays", "delays"],
];

export default function HelpPage() {
  const router = useRouter();
  const { t } = useTranslation();
  const { setUserAttributes } = useActions();
  const [selected, setSelected] = useState<Help[]>(answers.help);
  const [error, setError] = useState(false);

  const toggle = (value: Help) => {
    const next = selected.includes(value) ? selected.filter((v) => v !== value) : [...selected, value];
    setSelected(next);
    answers.help = next;
    setError(false);
  };

  const next = () => {
    if (selected.length === 0) {
      setError(true);
      return;
    }
    setUserAttributes({ help_most: selected.join(","), help_most_count: selected.length });
    router.push("frequency");
  };

  return (
    <Page
      className="page--help"
      footer={
        <>
          <p className="error" role="alert">{error ? t("help.error") : ""}</p>
          <PrimaryButton dimmed={selected.length === 0} onPress={next}>{t("help.cta")}</PrimaryButton>
        </>
      }
    >
      <h1 className="lede--hint">{t("help.question")}</h1>
      <p className="hint">{t("help.hint")}</p>
      <div role="group">
        {OPTIONS.map(([value, key]) => (
          <Option key={value} multi selected={selected.includes(value)} onPress={() => toggle(value)}>
            {t(`help.${key}`)}
          </Option>
        ))}
      </div>
    </Page>
  );
}

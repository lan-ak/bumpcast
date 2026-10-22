import { useEffect, useState } from "react";
import { useHaptics, useTranslation } from "superwall/hooks";
import { useIsFocused } from "superwall/navigation";
import { useNext } from "../components/next";
import { Page, PrimaryButton } from "../components/ui";

const BARS = [2, 3, 3, 4, 3, 9, 12, 10, 4, 3, 3, 2, 3, 3, 4, 3, 3, 8, 11, 4, 3, 3, 2, 2, 3, 2];
const STAGES = [
  { key: "stage1", confirmed: false, badgeColor: "var(--ink-2)" },
  { key: "stage2", confirmed: true, badgeColor: "var(--accent)" },
  { key: "stage3", confirmed: true, badgeColor: "var(--accent)" },
] as const;

export default function How() {
  const next = useNext("help");
  const { t } = useTranslation();
  const haptics = useHaptics();
  const focused = useIsFocused();
  const [stage, setStage] = useState(0);
  const [auto, setAuto] = useState(true);

  // Steps through the three stages on its own until the user taps a dot.
  useEffect(() => {
    if (!focused || !auto) return;
    const timer = setInterval(() => setStage((s) => (s + 1) % STAGES.length), 3600);
    return () => clearInterval(timer);
  }, [focused, auto]);

  const current = STAGES[stage];
  return (
    <Page
      footer={
        <>
          <p className="secondary footnote" style={{ textAlign: "center", marginBottom: 10 }}>{t("how.pro")}</p>
          <PrimaryButton onPress={next}>{t("how.cta")}</PrimaryButton>
        </>
      }
    >
      <div className="page-body spread">
        <div>
          <h1>{t("how.title")}</h1>
          <p className="secondary">{t("how.body")}</p>
        </div>
        <div>
          <div className="card" style={{ padding: 20 }} aria-live="polite">
            <div className="stage-head">
              <p className="eyebrow stage-when">{t(`how.${current.key}When`)}</p>
              <span className="badge" style={{ color: current.badgeColor }}>{t(`how.${current.key}Badge`)}</span>
            </div>
            <div className="bars" aria-hidden="true">
              {BARS.map((b, i) => (
                <div
                  key={i}
                  className="bar"
                  style={{
                    height: `${Math.round(((current.confirmed ? b : Math.max(3, b * 0.75)) / 12) * 106)}px`,
                    background: b > 7 ? "var(--light-chop)" : "var(--smooth)",
                    opacity: current.confirmed ? 1 : 0.4,
                  }}
                />
              ))}
            </div>
            <div className="stage-line">{t(`how.${current.key}Line`)}</div>
          </div>
          <div className="dots">
            {STAGES.map((s, i) => (
              <button
                key={s.key}
                type="button"
                className="dot-button"
                aria-label={t(`how.${s.key}When`)}
                aria-pressed={i === stage}
                onClick={() => {
                  haptics.selection();
                  setAuto(false);
                  setStage(i);
                }}
              >
                <span className={`dot${i === stage ? " dot--on" : ""}`} />
              </button>
            ))}
          </div>
        </div>
      </div>
    </Page>
  );
}

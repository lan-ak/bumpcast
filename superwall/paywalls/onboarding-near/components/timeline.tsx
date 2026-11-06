import { useTranslation } from "superwall/hooks";
import "./near.css";

export interface Step {
  key: string;
  when: string;
  line: string;
  /** Already true (filled dot), as against still to come (hollow). */
  done?: boolean;
  /** What Pro adds, tagged so it doesn't read as free. */
  pro?: boolean;
}

/** What happens next for this flight, top to bottom, on one line. Used by both flight paywalls. */
export function Timeline({ steps }: { steps: Step[] }) {
  const { t } = useTranslation();
  return (
    <ol className="near-steps">
      {steps.map((s) => (
        <li key={s.key} className={`near-step near-step--${s.key}`}>
          <span className={`near-dot${s.done ? " near-dot--on" : ""}`} aria-hidden="true" />
          <span className="near-when">
            {s.when}
            {s.pro && <span className="near-pro">{t("timeline.pro")}</span>}
          </span>
          <span className="near-line">{s.line}</span>
        </li>
      ))}
    </ol>
  );
}

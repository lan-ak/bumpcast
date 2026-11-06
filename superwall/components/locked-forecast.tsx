import "./locked-forecast.css";

export type Grade = "smooth" | "mostly_smooth" | "some_bumps" | "bumpy" | "rough";
type Kind = "calm" | "smooth" | "light" | "bumpy";

// Widths of the flight's stretches, takeoff to landing, and which ones carry the bumps for each
// grade. Shapes only: no times or words under the blur, so it never promises bumps the forecast
// doesn't have, and the real forecast never ships in the page.
const WIDTHS = [8, 22, 14, 30, 9, 17];
const BUMPS: Record<Grade, (Kind | null)[]> = {
  smooth: [null, null, null, null, null, null],
  mostly_smooth: ["light", null, null, null, null, null],
  some_bumps: ["light", null, "light", null, "light", null],
  bumpy: ["light", null, "bumpy", null, "light", null],
  rough: ["bumpy", null, "bumpy", null, "bumpy", null],
};

/**
 * The flight's forecast, blurred, under a lock: what the page sells, shown rather than described.
 * With a grade the stretches take its colours (smooth stays smooth); without one they're neutral.
 */
export function LockedForecast({ head, title, grade, compact }: { head: string; title: string; grade?: Grade; compact?: boolean }) {
  const kinds: Kind[] = grade ? BUMPS[grade].map((k) => k ?? "smooth") : WIDTHS.map(() => "calm");
  const rows = kinds.map((kind, i) => ({ kind, i })).filter((r) => r.kind === "light" || r.kind === "bumpy");
  const shown = (rows.length > 0 ? rows : kinds.slice(0, 3).map((kind, i) => ({ kind, i: i * 2 }))).slice(0, 3);
  return (
    <div className={`lf${compact ? " lf--compact" : ""}`}>
      <p className="lf-head">{head}</p>
      <div className="lf-body" aria-hidden="true">
        <div className="lf-strip">
          {kinds.map((kind, i) => <span key={i} className={`lf-${kind}`} style={{ width: `${WIDTHS[i]}%` }} />)}
        </div>
        {shown.map(({ kind, i }) => (
          <div key={i} className="lf-row">
            <span className="lf-time" />
            <span className={`lf-dot lf-${kind}`} />
            <span className="lf-bar" style={{ width: `${48 + ((i * 7) % 20)}%` }} />
          </div>
        ))}
      </div>
      <div className="lf-over">
        <span className="lf-icon">
          <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
            <rect x="5" y="11" width="14" height="10" rx="2" fill="none" stroke="currentColor" strokeWidth="2.2" />
            <path d="M8 11V7a4 4 0 0 1 8 0v4" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
          </svg>
        </span>
        <span className="lf-title">{title}</span>
      </div>
    </div>
  );
}

import { useEffect, useRef, useState, type PropsWithChildren } from "react";
import { useHaptics, useSuperwallSnapshot, useTranslation, useUser } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import "./theme.css";

/**
 * The question flow, in order, for the progress bar. The welcome, plans, and the flying-soon pages
 * after notifications (find, checking, flight) have no chrome: there's no going back from them.
 */
const STEPS = ["feeling", "reassure", "how", "help", "frequency", "when", "source", "notifications"] as const;

/**
 * How the "Calm line" sunrise behind the pages behaves on each page: the full logo scene on the
 * welcome, rising into the empty space under the questions, and faded out where content needs
 * the room.
 */
type SceneMode = "hero" | "fill" | "off";
const SCENE: Record<string, SceneMode> = {
  index: "hero",
  feeling: "fill",
  help: "fill",
  frequency: "fill",
  when: "fill",
  source: "fill",
};

/**
 * The app sends its real safe-area insets (`safe_area_top`, `safe_area_bottom`) because Superwall
 * infers them from the device model, which simulators and new models don't report. They become
 * the framework's floors, so `env()` still wins wherever the webview reports a safe area.
 */
function useHostSafeArea() {
  const user = useUser();
  const top = Number(user?.safe_area_top);
  const bottom = Number(user?.safe_area_bottom);
  useEffect(() => {
    const root = document.documentElement.style;
    if (Number.isFinite(top) && top > 0) root.setProperty("--sw-safe-area-floor-top", `${top}px`);
    if (Number.isFinite(bottom) && bottom > 0) root.setProperty("--sw-safe-area-floor-bottom", `${bottom}px`);
  }, [top, bottom]);
}

export default function Layout({ children }: PropsWithChildren) {
  const router = useRouter();
  const haptics = useHaptics();
  const { t } = useTranslation();
  const opened = useSuperwallSnapshot().paywall !== undefined;
  useHostSafeArea();

  const name = router.name;
  const mode: SceneMode = SCENE[name] ?? "off";
  const step = STEPS.indexOf(name as (typeof STEPS)[number]);
  const showChrome = step >= 0;
  const night = name === "notifications";

  // Arriving at a "fill" page from a page without the scene: start it below the screen so it
  // rises into place instead of fading in where it stands.
  const previous = useRef<SceneMode>(mode);
  const [rising, setRising] = useState(false);
  useEffect(() => {
    if (mode === "fill" && previous.current === "off") {
      setRising(true);
      const frame = requestAnimationFrame(() => requestAnimationFrame(() => setRising(false)));
      previous.current = mode;
      return () => cancelAnimationFrame(frame);
    }
    previous.current = mode;
  }, [mode]);

  // The sun climbs a little with every step.
  const progress = step >= 0 ? (step + 1) / STEPS.length : 0;
  const sunOffset = mode === "hero" ? 20 : Math.round(20 - progress * 40);

  return (
    <div className={`shell${night ? " shell--night" : ""}`}>
      <div className="backdrop" aria-hidden="true">
        <div className="backdrop-night" />
        <svg
          className={`scene scene--${mode}${rising ? " scene--rising" : ""}`}
          viewBox="0 0 390 420"
          preserveAspectRatio="xMidYMax slice"
        >
          <defs>
            <linearGradient id="water" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" className="water-top" />
              <stop offset="1" className="water-bottom" />
            </linearGradient>
          </defs>
          <g className="scene-sun" style={{ transform: `translateY(${sunOffset}px)` }}>
            <circle cx="250" cy="150" r="54" />
          </g>
          <rect className="scene-water" x="0" y="150" width="390" height="270" />
          <g className="scene-reflections">
            <line x1="221" y1="179" x2="279" y2="179" />
            <line x1="236" y1="197" x2="264" y2="197" />
          </g>
          <path
            className={`scene-line${opened ? " scene-line--drawn" : ""}`}
            d="M50 150 C80 150 92 114 118 114 S156 150 186 150 L420 150"
          />
        </svg>
      </div>

      <div className={`chrome${showChrome ? "" : " chrome--hidden"}`}>
        <button
          type="button"
          className="round-button"
          aria-label={t("chrome.back")}
          tabIndex={showChrome ? 0 : -1}
          onClick={() => {
            haptics.light();
            if (router.canGoBack()) router.back();
          }}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M15 5 L8 12 L15 19" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <div className="progress" role="progressbar" aria-valuemin={0} aria-valuemax={STEPS.length} aria-valuenow={step + 1}>
          <div className="progress-fill" style={{ width: `${Math.round(progress * 100)}%` }} />
        </div>
        <span className="chrome-spacer" />
      </div>

      {children}
    </div>
  );
}

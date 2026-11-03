import { useEffect } from "react";
import { useUser } from "superwall/hooks";

type Edge = "top" | "right" | "bottom" | "left";

/**
 * The app sends its window's real safe-area insets (`safe_area_top`, `_right`, `_bottom`, `_left`)
 * each time a paywall opens, because Superwall infers them from the device model, which
 * simulators and new models (the iPhone Duo, whose camera column runs down the right edge when
 * closed) don't report. They become the framework's floors, so `env()` still wins wherever the
 * webview reports a safe area. Builds before 1.0.4 send only top and bottom, and the rest keep the
 * framework's own floors. Pass only the edges the page reaches: a modal sheet starts below the
 * window's top inset, so it leaves `top` out.
 */
export function useHostSafeArea(edges: readonly Edge[] = ["top", "right", "bottom", "left"]) {
  const user = useUser();
  const insets = edges.map((edge) => `${edge}:${Number(user?.[`safe_area_${edge}`])}`).join(",");
  useEffect(() => {
    const root = document.documentElement.style;
    for (const pair of insets.split(",")) {
      const [edge, raw] = pair.split(":");
      const value = Number(raw);
      // 0 counts: unfolded, the Duo's right edge is clear again.
      if (Number.isFinite(value) && value >= 0) root.setProperty(`--sw-safe-area-floor-${edge}`, `${value}px`);
    }
  }, [insets]);
}

import { useEffect, useRef } from "react";
import { useIsFocused, useRouter, type RouteName } from "superwall/navigation";

/**
 * Moves on to `route` once per visit. The router keeps every page in the stack mounted, so a
 * second tap, or a delayed advance that lands after the page was left, would otherwise push
 * the next page again and Back would return to a duplicate. Single-select answers pass a delay
 * so the selection shows before the page moves.
 */
export function useNext(route: RouteName, delay = 0) {
  const router = useRouter();
  const focused = useIsFocused();
  const live = useRef({ router, focused });
  live.current = { router, focused };
  const pending = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  // Back on this page: it can move on again.
  useEffect(() => {
    if (focused) pending.current = false;
  }, [focused]);
  useEffect(() => () => clearTimeout(timer.current), []);

  return () => {
    if (pending.current || !live.current.focused) return;
    pending.current = true;
    const go = () => {
      if (live.current.focused) live.current.router.push(route);
      else pending.current = false;
    };
    if (delay > 0) timer.current = setTimeout(go, delay);
    else go();
  };
}

import { useEffect, useRef } from "react";
import { useActions, useSuperwallSnapshot, useUser } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import Welcome from "../../onboarding/app/index";
import { flight } from "../../onboarding/components/flight";
import { Page } from "../../onboarding/components/ui";
import { HARD_OPEN_KEY, leftHardOffer, resume, savedHardFlight } from "../components/near";

/**
 * The welcome, unless an earlier launch left them on the hard offer (they quit the app rather than
 * buy): then straight back to it, through the same forecast check, for the same flight. Once that
 * flight has departed they get the closable Plans instead.
 */
export default function Index() {
  const user = useUser();
  const router = useRouter();
  const resumed = useRef(false);
  const saved = savedHardFlight(user);
  const { setUserAttributes } = useActions();
  const opened = useSuperwallSnapshot().paywall !== undefined;

  // Shown, not just preloaded (the user's attributes are in by then): no offer to go back to, so
  // Forecast moments can open again once this flow is done.
  useEffect(() => {
    if (opened && !saved && user[HARD_OPEN_KEY] === true) setUserAttributes({ [HARD_OPEN_KEY]: false });
  }, [opened, saved, user, setUserAttributes]);

  useEffect(() => {
    if (resumed.current) return;
    if (!saved && leftHardOffer(user)) {
      resumed.current = true;
      router.replace("plans", { transition: "fade" });
      return;
    }
    // Only once shown: Superwall preloads the page at launch, before the app has registered the
    // placement whose handler answers `flight_forecast`, so a check started then fails at once and
    // ends on the offer without its forecast (0BDB7267, Nov 7).
    if (!saved || !opened) return;
    resumed.current = true;
    flight.added = saved;
    resume.active = true;
    router.replace("checking", { transition: "fade" });
  }, [saved, opened, user, router]);

  // Going back to the offer: an empty sky until shown, rather than a flash of the welcome.
  return saved ? <Page>{null}</Page> : <Welcome />;
}

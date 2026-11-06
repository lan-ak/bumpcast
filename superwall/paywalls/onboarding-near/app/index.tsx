import { useEffect, useRef } from "react";
import { useActions, useSuperwallSnapshot, useUser } from "superwall/hooks";
import { useRouter } from "superwall/navigation";
import Welcome from "../../onboarding/app/index";
import { flight } from "../../onboarding/components/flight";
import { HARD_OPEN_KEY, resume, savedHardFlight } from "../components/near";

/**
 * The welcome, unless an earlier launch left them on the hard offer (they quit the app rather than
 * buy): then straight back to it, through the same forecast check, for the same flight. Once the
 * flight has landed (12 hours past departure) they get the whole flow again, which ends soft.
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
    if (!saved || resumed.current) return;
    resumed.current = true;
    flight.added = saved;
    resume.active = true;
    router.replace("checking", { transition: "fade" });
  }, [saved, router]);

  return <Welcome />;
}

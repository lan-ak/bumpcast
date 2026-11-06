import Plans from "../../onboarding/app/plans";
import { flight } from "../../onboarding/components/flight";
import { fliesWithin24h, resume } from "../components/near";
import NearTrial from "../components/trial";

/** Plans, unless this launch resumed the hard trial and the forecast check then failed (the app
 * couldn't answer): the trial again, with the forecast still on its way, so it can't be skipped. */
export default function PlansRoute() {
  return resume.active && fliesWithin24h(flight.added) ? <NearTrial /> : <Plans />;
}

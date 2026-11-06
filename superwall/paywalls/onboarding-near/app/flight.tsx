import { flight } from "../../onboarding/components/flight";
import { fliesWithin24h } from "../components/near";
import SoftTimeline from "../components/soft";
import NearTrial from "../components/trial";

/** A flight leaving within 24 hours gets the trial (hard); any other, Yearly and Monthly (soft). */
export default function Flight() {
  return fliesWithin24h(flight.added) ? <NearTrial /> : <SoftTimeline />;
}

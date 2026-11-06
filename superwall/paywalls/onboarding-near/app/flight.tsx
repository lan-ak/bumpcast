import { flight } from "../../onboarding/components/flight";
import { fliesWithin24h } from "../components/near";
import SoftTimeline from "../components/soft";
import NearOffer from "../components/offer";

/** A flight leaving within 24 hours gets Yearly or a pass (hard); any other, Yearly and Monthly (soft). */
export default function Flight() {
  return fliesWithin24h(flight.added) ? <NearOffer /> : <SoftTimeline />;
}

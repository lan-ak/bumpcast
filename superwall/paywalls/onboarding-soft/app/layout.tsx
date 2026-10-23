import { variant } from "../../onboarding/components/variant";
import Layout from "../../onboarding/app/layout";

// The soft side of the hard-vs-soft test: the onboarding flow, page for page, with a close button
// on the flight paywall and the pass offer. Set before any page renders.
variant.soft = true;

export default Layout;

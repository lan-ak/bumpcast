import { variant } from "../../onboarding/components/variant";
import Layout from "../../onboarding/app/layout";

// The near-flier test: the soft flow (closable flight paywall), plus the trial and pass pages for
// a flight that leaves within 24 hours. Set before any page renders.
variant.soft = true;
variant.near = true;

export default Layout;

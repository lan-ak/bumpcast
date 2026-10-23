import { useEffect, useRef } from "react";
import { useActions, useTranslation } from "superwall/hooks";
import { useIsFocused, useRouter } from "superwall/navigation";
import { flight, parseForecast } from "../components/flight";
import { Page } from "../components/ui";

/** Long enough to read the line, short enough not to feel like a wait. */
const MINIMUM_MS = 2600;

/**
 * The first forecast for the flight just added: the app waits for it (`flight_forecast`, up to
 * about 20 s) while this page shows. Then the flight's paywall, or the plans for a flight outside
 * forecast coverage (nothing to sell for it, so nothing locked) or one the app couldn't check.
 */
export default function Checking() {
  const { t } = useTranslation();
  const router = useRouter();
  const focused = useIsFocused();
  const { requestCallback } = useActions();
  const started = useRef(false);
  const added = flight.added;

  useEffect(() => {
    if (!focused || started.current) return;
    started.current = true;
    if (!added) {
      router.replace("plans");
      return;
    }
    const shown = Date.now();
    void requestCallback("flight_forecast", { variables: { flight_id: added.id } }).then(async (result) => {
      flight.forecast = parseForecast(result.status === "success" ? result.data : undefined);
      const wait = MINIMUM_MS - (Date.now() - shown);
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      // The flight's paywall only for a flight the app could check: anything else (outside
      // coverage, or the app couldn't answer) gets the closable plans.
      const hard = result.status === "success" && flight.forecast.state !== "out_of_coverage";
      router.replace(hard ? "flight" : "plans", { transition: "fade" });
    });
  }, [focused, added, requestCallback, router]);

  return (
    <Page>
      <div className="page-body checking" style={{ justifyContent: "center" }} role="status" aria-live="polite">
        <svg className="checking-line" viewBox="0 0 240 60" aria-hidden="true">
          <path d="M8 46 C48 46 62 14 96 14 S144 46 176 46 L232 46" />
        </svg>
        <h1>{added ? t("checking.title", { route: `${added.origin} → ${added.destination}` }) : t("checking.titleBare")}</h1>
        <p className="secondary">{t("checking.body")}</p>
      </div>
    </Page>
  );
}

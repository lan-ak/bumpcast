import { useTranslation } from "superwall/hooks";
import { AIRPORT_CITIES } from "@/components/pro/airports";
import { departureText, type AddedFlight, type FlightForecast } from "./flight";

function End({ code, align }: { code: string; align: "start" | "end" }) {
  const city = AIRPORT_CITIES[code];
  return (
    <div className={`tk-end tk-end--${align}`}>
      <span className="tk-code">{code}</span>
      {city && <span className="tk-city">{city}</span>}
    </div>
  );
}

/** The flight just added, big: departure time, both airports and how sure the forecast is. */
export function Ticket({ added, forecast }: { added: AddedFlight; forecast?: FlightForecast }) {
  const { t } = useTranslation();
  // No pill for an early forecast: "too early to predict" above a grade undercuts it.
  const pill = forecast?.state === "ready" && forecast.confidence && forecast.confidence !== "early"
    ? t(`forecast.confidence.${forecast.confidence}`)
    : undefined;
  return (
    <div className="tk">
      <p className="tk-top">{t("flight.departs", { time: departureText(added) })}</p>
      <div className="tk-row">
        <End code={added.origin} align="start" />
        <svg className="tk-path" viewBox="0 0 80 24" aria-hidden="true">
          <path d="M2 18 C22 18 28 6 40 6 S58 18 78 18" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="3 4" strokeLinecap="round" />
          <path d="M36 2.5 41.5 6 36 9.5 37 6z" fill="currentColor" />
        </svg>
        <End code={added.destination} align="end" />
      </div>
      {pill && (
        <div className="tk-pills">
          <span className="tk-pill">{pill}</span>
        </div>
      )}
    </div>
  );
}

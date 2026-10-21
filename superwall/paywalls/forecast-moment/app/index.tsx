import { useTranslation } from "superwall/hooks";
import { AIRPORT_CITIES } from "@/components/pro/airports";
import { usePlacementContext, type FlightContext } from "@/components/pro/context";
import { ProPaywall } from "@/components/pro/paywall";
import "./ticket.css";

/** "YYZ → EWR" → ["YYZ", "EWR"]. Anything else (no arrow, odd codes) means no ticket. */
function codes(route?: string): [string, string] | undefined {
  const parts = route?.split("→").map((p) => p.trim());
  return parts?.length === 2 && parts[0] && parts[1] ? [parts[0], parts[1]] : undefined;
}

function End({ code, align }: { code: string; align: "start" | "end" }) {
  const city = AIRPORT_CITIES[code];
  return (
    <div className={`tk-end tk-end--${align}`}>
      <span className="tk-code">{code}</span>
      {city && <span className="tk-city">{city}</span>}
    </div>
  );
}

/**
 * The flight, big, from the params every shipped build sends (route, hours, confidence): no app
 * update needed. Cities come from the bundled airport list.
 */
function Ticket({ flight, ends }: { flight: FlightContext; ends: [string, string] }) {
  const { t } = useTranslation();
  const hours = flight.hours !== undefined && flight.hours > 0 ? Math.round(flight.hours) : undefined;
  // No bumpy-minute count (how much and when is what Pro sells), and no pill for an early
  // forecast: "too early to predict" above a grade undercuts it.
  const pills = [flight.confidence && flight.confidence !== "early" && t(`forecast.confidence.${flight.confidence}`)].filter(
    (p): p is string => Boolean(p),
  );
  return (
    <div className="tk">
      <p className="tk-top">{hours !== undefined ? `${t("forecast.yourFlight")} · ${t("forecast.departsIn", { hours })}` : t("forecast.yourFlight")}</p>
      <div className="tk-row">
        <End code={ends[0]} align="start" />
        <svg className="tk-path" viewBox="0 0 80 24" aria-hidden="true">
          <path d="M2 18 C22 18 28 6 40 6 S58 18 78 18" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="3 4" strokeLinecap="round" />
          <path d="M36 2.5 41.5 6 36 9.5 37 6z" fill="currentColor" />
        </svg>
        <End code={ends[1]} align="end" />
      </div>
      {pills.length > 0 && (
        <div className="tk-pills">
          {pills.map((p) => <span key={p} className="tk-pill">{p}</span>)}
        </div>
      )}
    </div>
  );
}

/**
 * Soft paywall: the user's flight and forecast on the sky. It fires when they need this flight, so
 * the pass leads; "More options" opens Yearly and Monthly. No flight means Pro leads, as elsewhere.
 */
export default function ForecastMoment() {
  const { t } = useTranslation();
  const { flight } = usePlacementContext();
  const ends = codes(flight.route);
  const inHours = flight.hours !== undefined && flight.hours > 0 ? Math.round(flight.hours) : undefined;
  // With the ticket showing, the route and hours are on it already.
  const eyebrow = ends
    ? t("forecast.eyebrowBare")
    : flight.route && inHours !== undefined
      ? t("forecast.eyebrowHours", { route: flight.route, hours: inHours })
      : flight.route
        ? t("forecast.eyebrow", { route: flight.route })
        : t("forecast.eyebrowBare");
  return (
    <ProPaywall
      lead="pass"
      moreOptions
      short
      hero={ends && <Ticket flight={flight} ends={ends} />}
      eyebrow={eyebrow}
      title={flight.gradeTitle ?? t("forecast.gradeBare")}
      subtitle={t("forecast.sub")}
      highlight="timeline_locked"
    />
  );
}

import { useTranslation } from "superwall/hooks";
import { usePlacementContext } from "@/components/pro/context";
import { ProPaywall } from "@/components/pro/paywall";

/** Soft paywall: the user's own forecast on the sky, then the same offer as the Pro paywalls. */
export default function ForecastMoment() {
  const { t } = useTranslation();
  const { flight } = usePlacementContext();
  const eyebrow =
    flight.route && flight.hours !== undefined && flight.hours > 0
      ? t("forecast.eyebrowHours", { route: flight.route, hours: Math.round(flight.hours) })
      : flight.route
        ? t("forecast.eyebrow", { route: flight.route })
        : t("forecast.eyebrowBare");
  return (
    <ProPaywall
      lead="pro"
      eyebrow={eyebrow}
      title={flight.gradeTitle ?? t("forecast.gradeBare")}
      subtitle={t("forecast.sub")}
      highlight="timeline_locked"
    />
  );
}

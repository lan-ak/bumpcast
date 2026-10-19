-- Worldwide forecasts. Apply before turning on SMOOTH_GLOBAL=1 in the worker.
alter table public.forecasts
  -- Which source covers each stretch of the flight: [{start_min, end_min, source}].
  -- A route can switch by place (GTG over the US, our GFS outlook elsewhere), not just by time.
  add column sources jsonb not null default '[]',
  -- Stretches raised by an official warning (SIGMET) or a recent pilot report:
  -- [{start_min, end_min, kind, hazard, severity, label}]
  add column warnings jsonb not null default '[]',
  -- Whether NOAA's detailed forecast (GTG) can ever cover the whole route. False for
  -- international routes, which stay an outlook: the app mustn't promise a confirmation.
  -- Null on forecasts from before worldwide coverage.
  add column noaa_possible boolean;

comment on column public.forecasts.status is
  '''ready'': forecast computed; ''too_early'': departure is more than 48h out; '
  '''out_of_coverage'': no source covers the route (before worldwide coverage: it left the US domain).';

-- After-landing ratings, split by how the forecast was made, so the global outlook can be
-- measured on its own and never blurs the accuracy we quote for confirmed forecasts.
alter table public.landing_reports
  -- Copied from the forecast: false = an international route NOAA could never confirm.
  add column forecast_noaa_possible boolean,
  -- Share of the flight's minutes that came from our GFS outlook (0 = all NOAA GTG).
  add column forecast_outlook_share real check (forecast_outlook_share between 0 and 1),
  -- Whether an official warning or pilot report raised any stretch of the forecast.
  add column forecast_warned boolean;

create or replace function public.fill_landing_report() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  fc record;
begin
  select fo.source, fo.segments, fo.sources, fo.warnings, fo.noaa_possible into fc
  from public.forecasts fo
  join public.flights fl on fl.id = fo.flight_id
  where fo.flight_id = new.flight_id and fo.status = 'ready' and fo.issued_at <= fl.departure_at
  order by fo.issued_at desc
  limit 1;

  if found then
    new.forecast_source := fc.source;
    select coalesce(
      (select s->>'severity' from jsonb_array_elements(fc.segments) s
       order by public.severity_rank(s->>'severity') desc limit 1),
      'smooth') into new.forecast_worst;
    new.matched := case
      when new.felt_relative is not null then new.felt_relative = 'about_right'
      else new.forecast_worst = new.felt
    end;
    new.forecast_noaa_possible := fc.noaa_possible;
    new.forecast_warned := jsonb_array_length(fc.warnings) > 0;
    -- Older forecasts have no per-stretch sources: all-GFS counts as outlook, anything else as NOAA.
    new.forecast_outlook_share := case
      when jsonb_array_length(fc.sources) = 0 then case when fc.source = 'gfs' then 1 else 0 end
      else (
        select sum(((s->>'end_min')::int - (s->>'start_min')::int + 1)
                   * case when s->>'source' = 'gfs' then 1 else 0 end)::real
             / nullif(sum((s->>'end_min')::int - (s->>'start_min')::int + 1), 0)
        from jsonb_array_elements(fc.sources) s
      )
    end;
  else
    new.forecast_worst := null;
    new.forecast_source := null;
    new.matched := null;
    new.forecast_noaa_possible := null;
    new.forecast_outlook_share := null;
    new.forecast_warned := null;
  end if;
  return new;
end;
$$;

-- The public numbers keep their meaning: flights NOAA can cover. International outlook
-- flights (forecast_noaa_possible = false) are measured separately by outlook_accuracy().
-- Before this, a route that started under NOAA and continued on the outlook ('mixed')
-- would have counted as confirmed.
create or replace function public.accuracy_stats()
returns table (reports bigint, exact bigint, within_one bigint, confirmed_reports bigint, confirmed_exact bigint)
language sql stable security definer set search_path = '' as $$
  select
    count(*),
    count(*) filter (where matched),
    count(*) filter (where matched or (felt is not null
      and abs(public.severity_rank(felt) - public.severity_rank(forecast_worst)) <= 1)),
    count(*) filter (where forecast_source in ('gtg', 'mixed')),
    count(*) filter (where matched and forecast_source in ('gtg', 'mixed'))
  from public.landing_reports
  where forecast_worst is not null and forecast_noaa_possible is not false;
$$;

-- Internal: how the global outlook is doing. The trust number is missed_bumps: we said
-- calm (smooth or light) and it felt moderate or worse, or "bumpier" than forecast.
create function public.outlook_accuracy()
returns table (
  reports bigint, exact bigint, within_one bigint, missed_bumps bigint, false_alarms bigint,
  warned_reports bigint, warned_exact bigint
)
language sql stable security definer set search_path = '' as $$
  select
    count(*),
    count(*) filter (where matched),
    count(*) filter (where matched or (felt is not null
      and abs(public.severity_rank(felt) - public.severity_rank(forecast_worst)) <= 1)),
    count(*) filter (where public.severity_rank(forecast_worst) <= 1
      and (public.severity_rank(felt) >= 2 or felt_relative = 'bumpier')),
    count(*) filter (where public.severity_rank(forecast_worst) >= 2
      and (felt = 'smooth' or felt_relative = 'smoother')),
    count(*) filter (where forecast_warned),
    count(*) filter (where forecast_warned and matched)
  from public.landing_reports
  where forecast_worst is not null and forecast_noaa_possible is false;
$$;

revoke execute on function public.outlook_accuracy() from public, anon, authenticated;
grant execute on function public.outlook_accuracy() to service_role;

-- Global outlook beta (opt-in). Null = never asked; the app's Settings switch, the
-- waitlist card and the add-flight question set it. Only people who turned it on are
-- notified about routes the outlook alone covers.
alter table public.profiles add column global_beta boolean;

-- One push to waitlist users when their route is covered: "A forecast for your flight is ready to try".
alter table public.notifications drop constraint notifications_milestone_check;
alter table public.notifications add constraint notifications_milestone_check
  check (milestone ~ '^(48h|24h|6h|2h|noaa|beta|schedule|cancelled|diverted|delay:[0-9T]+)$');
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('ready', 'update', 'confirmed', 'beta', 'delay', 'cancelled', 'diverted', 'schedule'));

-- Gusty takeoffs and landings (docs/design/gate-and-wind-brief.md, worker airfield.py). Where the
-- airport's own forecast has gusts of 25 kt or more around takeoff or landing, the worker tags the
-- climb or descent stretch there with cause 'wind_origin' or 'wind_destination' (inside segments).
-- airport_wind keeps what it decided for each end, and why: never shown, it's there to tune the
-- rules. Older forecasts have none.
alter table public.forecasts add column airport_wind jsonb not null default '[]';

-- Whether the forecast a rating is compared with had a gusty takeoff or landing.
alter table public.landing_reports add column forecast_wind boolean;

-- As in 20261023000100_landing_observations.sql, plus forecast_wind.
create or replace function public.fill_landing_report() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  fc record;
begin
  select fo.source, fo.segments, fo.sources, fo.warnings, fo.noaa_possible into fc
  from public.forecasts fo
  join public.flights fl on fl.id = fo.flight_id
  where fo.flight_id = new.flight_id and fo.status = 'ready'
    and fo.issued_at <= coalesce(new.forecast_issued_at + interval '1 second', fl.departure_at)
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
    new.forecast_wind := exists (
      select 1 from jsonb_array_elements(fc.segments) s where s->>'cause' in ('wind_origin', 'wind_destination')
    );
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
    new.forecast_wind := null;
  end if;
  return new;
end;
$$;

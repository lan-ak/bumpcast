-- What people noticed in the air, sent with the landing rating: when the seatbelt sign came on,
-- and which forecast their phone showed (it was offline in the air, so not always the latest).
alter table public.landing_reports
  -- Minutes after takeoff the user tapped "Seatbelt sign is on". Null when they never tapped.
  add column seatbelt_mins smallint[] check (cardinality(seatbelt_mins) <= 200),
  -- issued_at of the forecast the phone showed. Null from older app versions.
  add column forecast_issued_at timestamptz;

-- As in 20261019000000_global_coverage.sql, except the forecast compared with the rating: the one
-- the phone showed when it says so, else the last one issued before departure. A second of slack,
-- since the phone may round the time it was sent.
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

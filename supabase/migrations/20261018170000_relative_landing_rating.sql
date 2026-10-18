-- After-landing rating is now "How did it feel?": smoother / about right / bumpier than
-- the forecast. These ratings are the calibration data for the forecast.
alter table public.landing_reports
  add column felt_relative text check (felt_relative in ('smoother', 'about_right', 'bumpier')),
  alter column felt drop not null,
  add constraint landing_reports_has_rating check (felt is not null or felt_relative is not null);

create or replace function public.fill_landing_report() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  fc record;
begin
  select fo.source, fo.segments into fc
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
  else
    new.forecast_worst := null;
    new.forecast_source := null;
    new.matched := null;
  end if;
  return new;
end;
$$;

-- within_one: matched, or an absolute rating one level off.
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
  where forecast_worst is not null;
$$;

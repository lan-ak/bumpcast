-- MVP features: push notifications, Pro status, flight passes, landing reports,
-- accuracy stats, coverage waitlist, pilot reports and map grids.

-- Profile: what the worker needs to know about a user. The app reports Pro status
-- from Superwall; the worker only uses it to decide who gets update notifications.
create table public.profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  is_pro boolean not null default false,
  notifications_enabled boolean not null default false,
  timezone text,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
create policy "own profile: select" on public.profiles
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own profile: insert" on public.profiles
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own profile: update" on public.profiles
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create trigger profiles_touch_updated_at
before update on public.profiles
for each row execute function public.touch_updated_at();

-- APNs device tokens. A token can move between users (reinstall, new anonymous
-- account), so registration goes through a function that reassigns it.
create table public.devices (
  token text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  environment text not null check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now()
);

create index devices_user_idx on public.devices (user_id);
alter table public.devices enable row level security;
create policy "own devices: select" on public.devices
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own devices: delete" on public.devices
  for delete to authenticated using (user_id = (select auth.uid()));

create function public.register_device(p_token text, p_environment text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  insert into public.devices (token, user_id, environment)
  values (p_token, auth.uid(), p_environment)
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
end;
$$;

revoke execute on function public.register_device(text, text) from public, anon;
grant execute on function public.register_device(text, text) to authenticated;

-- Single-flight passes bought through Superwall. One App Store transaction unlocks one flight.
create table public.flight_passes (
  transaction_id text primary key,
  flight_id uuid not null references public.flights (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  product_id text not null,
  created_at timestamptz not null default now()
);

create index flight_passes_flight_idx on public.flight_passes (flight_id);
alter table public.flight_passes enable row level security;
create policy "own passes: select" on public.flight_passes
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own passes: insert" on public.flight_passes
  for insert to authenticated with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.flights f where f.id = flight_id and f.user_id = (select auth.uid()))
  );

-- Notifications the worker sent (or tried to). Doubles as the in-app "what changed" feed.
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  flight_id uuid not null references public.flights (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 48h | 24h | 6h | 2h | noaa
  milestone text not null check (milestone in ('48h', '24h', '6h', '2h', 'noaa')),
  -- ready: first forecast; update: later milestone; confirmed: NOAA now covers the flight
  kind text not null check (kind in ('ready', 'update', 'confirmed')),
  forecast_id uuid references public.forecasts (id) on delete set null,
  grade text,
  title text not null,
  body text not null,
  -- [{"text": "..."}] bullet points describing what changed and why
  changes jsonb not null default '[]',
  -- Free users get the 'ready' notification; updates are Pro (or a flight pass).
  pro_only boolean not null default false,
  delivered boolean not null default false,
  error text,
  created_at timestamptz not null default now(),
  unique (flight_id, milestone)
);

create index notifications_flight_idx on public.notifications (flight_id, created_at desc);
alter table public.notifications enable row level security;
create policy "own notifications: select" on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));

-- After-landing "How bumpy was it?" The forecast side is filled in by a trigger from
-- the last forecast issued before departure, so clients can't skew accuracy stats.
create table public.landing_reports (
  flight_id uuid primary key references public.flights (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  felt text not null check (felt in ('smooth', 'light', 'moderate', 'severe')),
  forecast_worst text check (forecast_worst in ('smooth', 'light', 'moderate', 'severe')),
  forecast_source text,
  matched boolean,
  comment text check (char_length(comment) <= 1000),
  created_at timestamptz not null default now()
);

alter table public.landing_reports enable row level security;
create policy "own reports: select" on public.landing_reports
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own reports: insert" on public.landing_reports
  for insert to authenticated with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.flights f
      where f.id = flight_id and f.user_id = (select auth.uid()) and f.departure_at < now()
    )
  );

create function public.severity_rank(s text) returns int
language sql immutable set search_path = '' as $$
  select case s when 'smooth' then 0 when 'light' then 1 when 'moderate' then 2 when 'severe' then 3 end;
$$;

create function public.fill_landing_report() returns trigger
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
    new.matched := new.forecast_worst = new.felt;
  else
    new.forecast_worst := null;
    new.forecast_source := null;
    new.matched := null;
  end if;
  return new;
end;
$$;

create trigger landing_reports_fill
before insert on public.landing_reports
for each row execute function public.fill_landing_report();

-- Public accuracy numbers for the app ("Our forecasts matched 81% of 240 flights").
create function public.accuracy_stats()
returns table (reports bigint, exact bigint, within_one bigint, confirmed_reports bigint, confirmed_exact bigint)
language sql stable security definer set search_path = '' as $$
  select
    count(*),
    count(*) filter (where matched),
    count(*) filter (where abs(public.severity_rank(felt) - public.severity_rank(forecast_worst)) <= 1),
    count(*) filter (where forecast_source in ('gtg', 'mixed')),
    count(*) filter (where matched and forecast_source in ('gtg', 'mixed'))
  from public.landing_reports
  where forecast_worst is not null;
$$;

grant execute on function public.accuracy_stats() to anon, authenticated;

-- "Tell me when you cover my region": demand per country.
create table public.waitlist (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  country text not null check (char_length(country) = 2),
  airport text,
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  primary key (user_id, country)
);

alter table public.waitlist enable row level security;
create policy "own waitlist: select" on public.waitlist
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own waitlist: insert" on public.waitlist
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own waitlist: delete" on public.waitlist
  for delete to authenticated using (user_id = (select auth.uid()));

create view public.waitlist_demand with (security_invoker = true) as
  select country, count(*) as signups from public.waitlist group by country;
revoke all on public.waitlist_demand from anon, authenticated;

-- Recent pilot reports of turbulence (from aviationweather.gov), kept for 6 hours.
create table public.pireps (
  id text primary key,
  observed_at timestamptz not null,
  lat double precision not null,
  lon double precision not null,
  altitude_ft integer,
  intensity text not null check (intensity in ('smooth', 'light', 'moderate', 'severe')),
  aircraft text,
  raw text
);

create index pireps_observed_idx on public.pireps (observed_at desc);
alter table public.pireps enable row level security;
create policy "pireps: read" on public.pireps for select to authenticated using (true);

-- Map layers: GTG turbulence on a regular lat/lon grid, one row per height and time.
-- cells is ny*nx characters, row-major from the north-west corner: '0' smooth .. '3' severe.
create table public.turbulence_grids (
  valid_at timestamptz not null,
  level_ft integer not null,
  cycle timestamptz not null,
  north double precision not null,
  west double precision not null,
  step double precision not null,
  ny integer not null,
  nx integer not null,
  cells text not null,
  primary key (valid_at, level_ft)
);

alter table public.turbulence_grids enable row level security;
create policy "grids: read" on public.turbulence_grids for select to authenticated using (true);

-- Core slice: saved flights and the forecasts the worker computes for them.

create table public.flights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  origin text not null check (char_length(origin) = 4),          -- ICAO, e.g. KJFK
  destination text not null check (char_length(destination) = 4),
  departure_at timestamptz not null,                              -- scheduled departure, UTC
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (origin <> destination)
);

create index flights_user_departure_idx on public.flights (user_id, departure_at);
create index flights_departure_idx on public.flights (departure_at);

create table public.forecasts (
  id uuid primary key default gen_random_uuid(),
  flight_id uuid not null references public.flights (id) on delete cascade,
  issued_at timestamptz not null default now(),
  -- 'ready': forecast computed; 'too_early': departure is more than 48h out;
  -- 'out_of_coverage': route leaves the US forecast domain.
  status text not null check (status in ('ready', 'too_early', 'out_of_coverage')),
  -- Which data drove the forecast: 'gtg' (NOAA GTG, <=18h), 'gfs' (our index, 18-48h) or 'mixed'.
  source text check (source in ('gtg', 'gfs', 'mixed')),
  model_run timestamptz,
  grade text check (grade in ('smooth', 'mostly_smooth', 'some_bumps', 'bumpy', 'rough')),
  score smallint check (score between 0 and 100),             -- 100 = glass smooth
  duration_min smallint,
  cruise_ft integer,
  -- Bumpy stretches: [{start_min, end_min, severity, peak_edr, phase, altitude_ft}]
  segments jsonb not null default '[]',
  -- Per-minute samples for the timeline chart: [{min, edr, altitude_ft}]
  samples jsonb not null default '[]',
  -- Sparse route polyline for the map: [[lat, lon], ...]
  route jsonb not null default '[]'
);

create index forecasts_flight_issued_idx on public.forecasts (flight_id, issued_at desc);

create function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger flights_touch_updated_at
before update on public.flights
for each row execute function public.touch_updated_at();

-- Row level security: users see only their own flights and those flights' forecasts.
-- The worker uses the service role key, which bypasses RLS.
alter table public.flights enable row level security;
alter table public.forecasts enable row level security;

create policy "own flights: select" on public.flights
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own flights: insert" on public.flights
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own flights: update" on public.flights
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own flights: delete" on public.flights
  for delete to authenticated using (user_id = (select auth.uid()));

create policy "own forecasts: select" on public.forecasts
  for select to authenticated using (
    exists (select 1 from public.flights f where f.id = flight_id and f.user_id = (select auth.uid()))
  );

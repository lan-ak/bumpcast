-- 1.1: flight numbers (search is free) and live flight status (Pro or a flight pass).
-- The app never names where flight data comes from.

-- Flight number and the airline's schedule, when the flight was found by search.
alter table public.flights
  add column flight_number text check (flight_number ~ '^[A-Z0-9]{2,3} [0-9]{1,4}[A-Z]?$'),  -- e.g. 'B6 23'
  add column airline_name text,
  add column arrival_at timestamptz,                         -- scheduled arrival, UTC
  -- Searched before the airline published this date: the user entered airports and time,
  -- and the worker fills in the schedule once it's out.
  add column schedule_pending boolean not null default false,
  add check (not schedule_pending or flight_number is not null);

-- The departure time a forecast was computed for. Differs from flights.departure_at when a
-- delay moved the forecast to the expected departure.
alter table public.forecasts add column departure_at timestamptz;

-- Latest status for a flight, written by the worker. Live status rows exist only for Pro
-- users and flights with a pass; a row with a null status only records schedule checks.
create table public.flight_status (
  flight_id uuid primary key references public.flights (id) on delete cascade,
  status text check (status in ('scheduled', 'delayed', 'departed', 'cancelled', 'diverted')),
  live boolean not null default false,  -- live times, not just the published schedule
  departure_scheduled timestamptz,
  departure_expected timestamptz,
  departure_actual timestamptz,
  arrival_scheduled timestamptz,
  arrival_expected timestamptz,
  arrival_actual timestamptz,
  delay_min integer,
  departure_gate text,
  departure_terminal text,
  arrival_terminal text,
  diverted_to text,                     -- ICAO
  checked_at timestamptz not null default now(),
  next_check_at timestamptz,
  finished boolean not null default false,  -- status updates have stopped for this flight
  -- What the user was last told, so a change is pushed once (and after quiet hours).
  notified_departure timestamptz,
  notified_status text
);

alter table public.flight_status enable row level security;
create policy "own flight status: select" on public.flight_status
  for select to authenticated using (
    exists (select 1 from public.flights f where f.id = flight_id and f.user_id = (select auth.uid()))
  );

-- Status and schedule notifications share the feed with forecast milestones.
alter table public.notifications drop constraint notifications_milestone_check;
alter table public.notifications add constraint notifications_milestone_check
  check (milestone ~ '^(48h|24h|6h|2h|noaa|schedule|cancelled|diverted|delay:[0-9T]+)$');
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('ready', 'update', 'confirmed', 'delay', 'cancelled', 'diverted', 'schedule'));

-- A different route, time or flight number makes the old status (and forecasts) wrong.
create or replace function public.reset_flight_on_edit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.departure_at is distinct from old.departure_at
     or new.origin is distinct from old.origin
     or new.destination is distinct from old.destination then
    delete from public.notifications where flight_id = new.id;
    delete from public.forecasts where flight_id = new.id;
  end if;
  if new.departure_at is distinct from old.departure_at
     or new.origin is distinct from old.origin
     or new.destination is distinct from old.destination
     or new.flight_number is distinct from old.flight_number then
    delete from public.flight_status where flight_id = new.id;
  end if;
  return new;
end;
$$;

-- Flight searches per user, for rate limiting the search function. Service role only.
create table public.flight_searches (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index flight_searches_user_idx on public.flight_searches (user_id, created_at desc);
alter table public.flight_searches enable row level security;

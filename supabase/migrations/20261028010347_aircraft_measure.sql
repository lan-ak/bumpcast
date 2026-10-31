-- Aircraft type, step 1: measure before building a turboprop profile (worker aircraft.py). Nothing
-- here is shown or pushed, and the app ignores these columns.

-- The provider's model text, as given. It goes with the status row (the worker deletes status 6
-- days after its last check). The registration itself is never stored, only whether there was one.
alter table public.flight_status
  add column aircraft_model text,
  add column aircraft_reg_present boolean,
  add column aircraft_first_seen_at timestamptz;  -- when a plane was first named for this flight

-- What BumpCast derives from those checks, kept after status is purged. No provider data.
create table public.flight_aircraft (
  flight_id uuid primary key references public.flights (id) on delete cascade,
  first_check_had_model boolean,                  -- the plane was named at the first status check
  first_check_hours real,                         -- hours before departure of that check
  model_first_seen_hours real,                    -- hours before departure the plane was first named
  model_changed boolean not null default false,   -- a different plane was named later
  turboprop boolean,                              -- Dash 8 or ATR, by the latest plane named
  updated_at timestamptz not null default now()
);

-- The worker's own: no policies, and no access for app roles.
alter table public.flight_aircraft enable row level security;
revoke all on table public.flight_aircraft from anon, authenticated;

-- The review, after two weeks and 30 real users' numbered flights (leave out the owner's and App
-- Review's accounts):
--   select count(*) as flights,
--          count(*) filter (where turboprop) as turboprop,
--          avg(first_check_had_model::int) as named_at_first_check,
--          percentile_cont(0.5) within group (order by model_first_seen_hours) as median_hours_named,
--          count(*) filter (where model_changed) as swapped
--   from public.flight_aircraft;

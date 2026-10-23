-- The Live Activity push carries the whole plan (stretches, duration, how confirmed), not just
-- the takeoff, and a newer forecast reaches a running activity quietly after wheels-up.

-- issued_at of the forecast last pushed to this activity, so each newer one is sent once.
alter table public.live_activities add column pushed_forecast_at timestamptz;

-- The worker no longer guesses wheels-up (gate time plus taxi): the app estimates that itself.
comment on column public.flight_status.takeoff_at is
  'Wheels-up the airline reported: its runway time, once that has passed. Null until then.';
comment on column public.flight_status.arrival_actual is
  'Landing, once the airline''s runway time has passed. Before that its estimate is in arrival_expected.';

-- A forecast the worker kept through a delay (NOAA's detailed forecast was unavailable, so it
-- couldn't be recomputed yet) and copied to the new departure. The worker retries it within
-- minutes, and neither the delay push nor the app says it was updated for the new time.
alter table public.forecasts add column retimed boolean not null default false;

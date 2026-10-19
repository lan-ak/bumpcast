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

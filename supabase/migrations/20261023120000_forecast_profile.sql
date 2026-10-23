-- Which version of the worker's flight profile (climb, cruise, descent, winds) built the forecast,
-- so the next update says the model changed instead of describing it as new weather. Null for
-- forecasts from before profiles were versioned.
alter table public.forecasts add column profile smallint;

-- The Sky Report: forecasts for a fixed list of popular routes at set departure times, built by
-- the worker every hour. It's marketing data (route pages and social cards), the same for
-- everyone and holding nothing about users, so anon reads it like the map. Only the latest
-- report is kept, under id 'latest'.
create table public.sky_reports (
  id text primary key,
  generated_at timestamptz not null,
  report jsonb not null
);

alter table public.sky_reports enable row level security;
create policy "sky reports: read" on public.sky_reports for select to anon, authenticated using (true);
revoke insert, update, delete, truncate, references, trigger on table public.sky_reports from anon, authenticated;

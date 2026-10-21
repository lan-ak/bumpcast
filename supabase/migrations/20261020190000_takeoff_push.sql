-- Live status is free for every flight with a number; Pro is about forecast updates.
-- Wheels-up from the airline's data re-times the in-flight countdown by push, so nobody has
-- to tap "We've taken off".

-- Best known wheels-up: the runway time when the airline reports it, else the actual departure
-- plus taxi. Null until the flight has left.
alter table public.flight_status add column takeoff_at timestamptz;

-- Push tokens for each flight's Live Activity. One activity per flight per device; a new token
-- (the activity was restarted) replaces the old one.
create table public.live_activities (
  token text primary key,
  flight_id uuid not null references public.flights (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  environment text not null check (environment in ('sandbox', 'production')),
  -- The takeoff last pushed to this activity, so each change is sent once.
  pushed_takeoff timestamptz,
  ended boolean not null default false,
  updated_at timestamptz not null default now()
);
create index live_activities_flight on public.live_activities (flight_id) where not ended;

alter table public.live_activities enable row level security;
create policy "own live activities: select" on public.live_activities
  for select to authenticated using (user_id = (select auth.uid()));

create function public.register_live_activity(p_flight_id uuid, p_token text, p_environment text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.flights f where f.id = p_flight_id and f.user_id = auth.uid()) then
    raise exception 'not your flight';
  end if;
  -- An older activity for the same flight is gone once a new one registers.
  update public.live_activities set ended = true, updated_at = now()
    where flight_id = p_flight_id and user_id = auth.uid() and token <> p_token;
  insert into public.live_activities (token, flight_id, user_id, environment)
  values (p_token, p_flight_id, auth.uid(), p_environment)
  on conflict (token) do update
    set flight_id = excluded.flight_id, user_id = excluded.user_id,
        environment = excluded.environment, ended = false, updated_at = now();
end;
$$;

create function public.end_live_activity(p_flight_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.live_activities set ended = true, updated_at = now()
  where flight_id = p_flight_id and user_id = auth.uid();
$$;

revoke all on function public.register_live_activity(uuid, text, text) from public, anon;
revoke all on function public.end_live_activity(uuid) from public, anon;
grant execute on function public.register_live_activity(uuid, text, text) to authenticated;
grant execute on function public.end_live_activity(uuid) to authenticated;


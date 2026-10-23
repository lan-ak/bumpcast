-- A phone whose session was lost (a refresh that failed on plane wifi, an unreadable keychain, a
-- restore to a new phone) can end up signed in as a new account. Its flights move over by id, with
-- their passes, reports, notifications and Live Activities. Only from an anonymous account, never
-- the caller's own, and only with proof that the call comes from the install that saved them.
--
-- The proof: each install keeps a random secret on the phone, beside the account id it remembers
-- (not only in the keychain, which may be what was lost), and saves its SHA-256 on its account's
-- profile. Flight and user ids alone aren't enough: both are sent to the paywall service.
--
-- user_id only: flights_reset_on_edit resets forecasts and status on a new route, time or number,
-- not on this. flights_touch_updated_at does bump updated_at, so the worker forecasts each moved
-- flight once more (it never swaps a confirmed forecast for less of one).

-- Lowercase hex SHA-256 of the install's secret. Never the secret itself.
alter table public.profiles add column adopt_secret_hash text check (char_length(adopt_secret_hash) <= 128);

create function public.adopt_flights(p_flight_ids uuid[], p_from_user uuid, p_secret text) returns setof uuid
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  moved uuid[] := '{}';
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if coalesce(cardinality(p_flight_ids), 0) > 200 then
    raise exception 'too many flights';
  end if;

  if p_from_user is distinct from me
     and coalesce(p_secret, '') <> ''
     and exists (select 1 from auth.users u where u.id = p_from_user and u.is_anonymous)
     and exists (
       select 1 from public.profiles p
       where p.user_id = p_from_user
         and lower(p.adopt_secret_hash) = encode(sha256(convert_to(p_secret, 'UTF8')), 'hex')
     ) then
    with m as (
      update public.flights f set user_id = me
      where f.id = any (p_flight_ids) and f.user_id = p_from_user
      returning f.id
    )
    select coalesce(array_agg(m.id), '{}') into moved from m;

    update public.notifications set user_id = me where flight_id = any (moved) and user_id = p_from_user;
    update public.flight_passes set user_id = me where flight_id = any (moved) and user_id = p_from_user;
    update public.landing_reports set user_id = me where flight_id = any (moved) and user_id = p_from_user;
    update public.live_activities set user_id = me, updated_at = now()
      where flight_id = any (moved) and user_id = p_from_user;
  end if;

  -- Every requested flight this account owns now: moved, or its own already.
  return query select f.id from public.flights f where f.id = any (p_flight_ids) and f.user_id = me;
end;
$$;

revoke all on function public.adopt_flights(uuid[], uuid, text) from public, anon;
grant execute on function public.adopt_flights(uuid[], uuid, text) to authenticated;

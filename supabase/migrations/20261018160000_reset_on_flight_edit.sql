-- When a flight's route or time changes, its forecasts and notifications describe a
-- different flight: drop them so the worker starts fresh ("ready" at 48 h again).
create function public.reset_flight_on_edit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.departure_at is distinct from old.departure_at
     or new.origin is distinct from old.origin
     or new.destination is distinct from old.destination then
    delete from public.notifications where flight_id = new.id;
    delete from public.forecasts where flight_id = new.id;
  end if;
  return new;
end;
$$;

create trigger flights_reset_on_edit
after update on public.flights
for each row execute function public.reset_flight_on_edit();

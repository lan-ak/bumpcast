-- A request sent with only the public key runs as anon. That happens when the app's token
-- refresh fails (plane wifi) and the SDK sends the request anyway. These tables hold each user's
-- own rows, with policies for signed-in users only, so anon used to get an empty answer, which
-- the phone took for "no flights" or "no forecast". With no privileges, anon gets a permission
-- error instead, and the phone keeps what it has.
--
-- Nothing else uses anon here. The app's anonymous accounts are signed in (role authenticated),
-- as is the flight-search function, which checks the caller with their own token and writes its
-- quota rows with the service role, like the worker. Triggers run as their owner or the caller,
-- and the RPCs were never granted to anon.
revoke all on table
  public.flights,
  public.forecasts,
  public.notifications,
  public.flight_passes,
  public.landing_reports,
  public.waitlist,
  public.profiles,
  public.devices,
  public.live_activities,
  public.flight_status,
  public.flight_searches
from anon;

-- The map's weather and pilot reports are the same for everyone: anon reads them too, so the map
-- still loads when a refresh fails, and writes nothing. accuracy_stats() stays open to anon too.
revoke insert, update, delete, truncate, references, trigger on table public.pireps, public.turbulence_grids from anon;
alter policy "pireps: read" on public.pireps to anon, authenticated;
alter policy "grids: read" on public.turbulence_grids to anon, authenticated;

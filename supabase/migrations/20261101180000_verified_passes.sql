-- Flight passes are checked with Apple before they unlock anything off the phone that bought them.
--
-- Until now the app inserted pass rows itself, and the insert policy only checked that the flight
-- was the caller's, so a hand-made row with an invented transaction_id unlocked a flight for free.
-- From 1.0.4 the app sends passes to the verify-pass function, which looks the transaction up with
-- Apple's App Store Server API and writes the row with verified_at set. Apps up to 1.0.3 still
-- insert rows directly; those arrive unverified, and the worker hands them to the same function.
--
-- Only verified rows count: the worker's Pro notifications and the 1.0.4 app read rows with
-- verified_at set. Rows already here are trusted as they are ('legacy'), so nobody loses a pass.

alter table public.flight_passes
  add column verified_at timestamptz,
  -- 'Production' or 'Sandbox' (Apple's answer), 'TestStore' (Superwall test store, allowed only
  -- while the function's ALLOW_TEST_STORE_PASSES is on), or 'legacy' for rows from before this.
  add column environment text,
  -- Apple said no (unknown transaction, another app, not a pass, refunded). Never retried.
  add column rejected_at timestamptz,
  add column verify_error text,
  add column verify_attempts integer not null default 0;

update public.flight_passes set verified_at = created_at, environment = 'legacy' where verified_at is null;

-- The worker's sweep looks for these.
create index flight_passes_unverified_idx on public.flight_passes (created_at)
  where verified_at is null and rejected_at is null;

-- Signed-in users can still insert (apps up to 1.0.3 do), but only the columns they always sent:
-- never verified_at or the other verification columns, which only the service role writes.
revoke insert, update on table public.flight_passes from authenticated;
grant insert (transaction_id, flight_id, user_id, product_id) on table public.flight_passes to authenticated;

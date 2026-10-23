-- Onboarding hard vs soft flight paywall: conversion in onboarding, and flight passes bought later.
--
-- The Onboarding campaign (113534) splits 50/50 between `onboarding` (paywall 281980, hard: the
-- flight paywall and pass offer can't be closed) and `onboarding-soft` (284375, both can). Only
-- people who say they fly in the next 3 days and add their flight (app 1.0.1+) reach the flight
-- paywall; everyone else sees the same closable Plans page in both. Each flow saves the
-- `onboarding_paywall_variant` user attribute ("hard" / "soft") when it opens.
--
-- Run: superwall query --file docs/superwall/onboarding-hard-vs-soft.sql
-- "Later passes" are flight passes bought on any paywall outside onboarding (forecast moments,
-- Pro features), so the soft side's closers who come back and buy show up there.
WITH variant AS (
  SELECT appUserId, argMax(value, ts) AS variant
  FROM sw.user_attributes_rep
  WHERE applicationId = '58179' AND key = 'onboarding_paywall_variant'
  GROUP BY appUserId
),
onboarding AS (
  SELECT appUserId,
    countIf(name = 'transaction_complete' AND JSONExtractString(props, '$paywall_identifier') IN ('onboarding', 'onboarding-soft')) > 0 AS converted_in_onboarding
  FROM sw.events_rep WHERE applicationId = '58179' GROUP BY appUserId
),
passes AS (
  SELECT appUserId, count() AS later_passes
  FROM sw.events_rep
  WHERE applicationId = '58179' AND name = 'transaction_complete'
    AND JSONExtractString(props, '$product_id') = 'bumpcast_flight_pass'
    AND JSONExtractString(props, '$paywall_identifier') NOT IN ('onboarding', 'onboarding-soft')
  GROUP BY appUserId
)
SELECT v.variant,
  count() AS users,
  sum(o.converted_in_onboarding) AS bought_in_onboarding,
  round(100 * sum(o.converted_in_onboarding) / count(), 1) AS onboarding_conversion_pct,
  countIf(p.later_passes > 0) AS later_pass_buyers,
  sum(p.later_passes) AS later_passes
FROM variant v
LEFT JOIN onboarding o ON o.appUserId = v.appUserId
LEFT JOIN passes p ON p.appUserId = v.appUserId
GROUP BY v.variant ORDER BY v.variant

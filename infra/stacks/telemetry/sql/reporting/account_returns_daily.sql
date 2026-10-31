-- The view dfo_reporting.account_returns_daily, a Terraform template
-- (reporting_views.tf): signed-in website accounts per UTC day of created_at,
-- from ${events}, the website export's copy of the Postgres event table.
-- Only signed-in events carry a user_hash, and only events with one count, so
-- a day with none has no row.
--
-- active_sketch is an HLL++ sketch of the day's user_hash values.
-- returning_sketch is the same over the accounts whose first signed-in event
-- in ${events} falls on an earlier day, and NULL when the day has none.
-- Merged over a window with HLL_COUNT.MERGE, active_sketch counts the accounts
-- active in it, and returning_sketch the accounts active on a day after their
-- first active day, each account once however many days it returned on. No
-- hashed id reaches readers.
SELECT
  day,
  HLL_COUNT.INIT(user_hash, 14) AS active_sketch,
  HLL_COUNT.INIT(IF(day > first_day, user_hash, NULL), 14) AS returning_sketch
FROM (
  SELECT
    DATE(created_at) AS day,
    user_hash,
    MIN(DATE(created_at)) OVER (PARTITION BY user_hash) AS first_day
  FROM `${events}`
  WHERE user_hash IS NOT NULL
)
GROUP BY day

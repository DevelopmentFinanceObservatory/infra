-- The view dfo_reporting.accounts_daily, a Terraform template
-- (reporting_views.tf): website accounts created per UTC day of the user's
-- created_at and organisation, read straight from ${accounts}, the website
-- export's account_daily table. The export groups the accounts in Postgres,
-- so no email address and no user id reaches BigQuery. organisation is the
-- lower-cased email domain when that domain holds at least 3 accounts in
-- total, Personal email for a webmail domain, and Other organisations
-- otherwise. A day with no new accounts has one row with organisation NULL
-- and accounts 0. accounts sums across rows.
SELECT
  day,
  organisation,
  accounts
FROM `${accounts}`

-- The view dfo_reporting.consumer_keys_daily, a Terraform template
-- (reporting_views.tf): person keys per whole UTC day and key kind across
-- every surface, how many returned from the 2 to 28 days before, and whether
-- the day looks like a rotated hashing key, as ${consumer_key_persistence_daily}
-- holds them. It holds no key.
SELECT
  day,
  key_kind,
  keys_seen,
  returning_keys,
  trailing_returning_keys,
  trailing_returning_share,
  keys_look_rotated
FROM `${consumer_key_persistence_daily}`

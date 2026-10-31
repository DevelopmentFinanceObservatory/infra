-- The view dfo_reporting.ga4_user_ranges, a Terraform template
-- (reporting_views.tf): GA4 Data API users over fixed date ranges from
-- ${ranges}, which the ga4-user-ranges workflow (ga4_user_ranges.tf)
-- replaces once a day. The Data API counts each user once over the whole
-- range, so these are the unique users over each range for every day GA4
-- holds, while ga4_daily's active users hold for their own day only. Like
-- every GA4 user figure, they count visitors who accepted analytics storage.
SELECT range_kind, range_start, range_end, active_users, total_users, new_users, fetched_at
FROM `${ranges}`

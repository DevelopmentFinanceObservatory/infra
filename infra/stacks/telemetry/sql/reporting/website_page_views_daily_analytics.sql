-- The view dfo_reporting.website_page_views_daily while
-- var.analytics_dbt_schedule_enabled is on, a Terraform template
-- (reporting_views.tf): the website's page views per UTC day, from people and
-- from bots, as ${website_page_views_daily} holds them. The analytics
-- repository's dbt model builds that table with website_page_views_daily.sql's
-- rule: the rebuilt history before the request log's first parsed day, and
-- the request log from then on.
SELECT
  day,
  page_views,
  bot_page_views
FROM `${website_page_views_daily}`

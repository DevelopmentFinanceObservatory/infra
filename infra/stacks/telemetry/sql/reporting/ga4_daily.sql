-- The view dfo_reporting.ga4_daily, a Terraform template
-- (reporting_views.tf): GA4 active users, sessions and page views per day in
-- the property's reporting time zone. Days from the GA4 BigQuery export's
-- first day on come from ${events}, its daily events_YYYYMMDD tables, and
-- days before it from ${history}, which scripts/load-ga4-history.sh fills from
-- the Data API. The seam is read from the export itself, so no day is
-- counted twice whatever range the history holds.
--
-- Users and sessions are distinct over the whole day, so they are not the
-- sum of ga4_pages_daily's rows. Active users do not sum across days.
-- Sessions do, except that a session crossing midnight counts on both days,
-- so a sum over several days runs slightly high. An active user is one the
-- export marks is_active_user, and a session is a user's ga_session_id, as
-- the Data API counts them. The export rows are exact counts and the
-- history rows are the Data API's estimates.
WITH
  events AS (
    SELECT
      PARSE_DATE('%Y%m%d', event_date) AS day,
      event_name,
      IF(is_active_user, user_pseudo_id, NULL) AS active_user,
      CONCAT(
        user_pseudo_id,
        '.',
        CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING)
      ) AS session
    FROM `${events}`
  ),
  export AS (
    SELECT
      day,
      COUNT(DISTINCT active_user) AS active_users,
      COUNT(DISTINCT session) AS sessions,
      COUNTIF(event_name IN ('page_view', 'screen_view')) AS page_views
    FROM events
    GROUP BY day
  )
SELECT date AS day, active_users, sessions, screen_page_views AS page_views
FROM `${history}`
WHERE date < IFNULL((SELECT MIN(day) FROM export), DATE '9999-12-31')
UNION ALL
SELECT day, active_users, sessions, page_views
FROM export

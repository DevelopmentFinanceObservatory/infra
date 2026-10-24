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
--
-- The site runs Google Consent Mode, so a visitor who declines analytics
-- storage still sends cookieless events, which the export marks
-- privacy_info.analytics_storage 'No' and gives no user_pseudo_id. The Data
-- API leaves them out. Those events carry no user or session, so active users
-- and sessions count accepted visitors only on every day. page_views counts
-- every visitor's page views on export days and accepted ones on history
-- days, and declined_page_views is the export days' declined part, NULL on
-- history days, where the Data API cannot report it. Accepted page views are
-- page_views - IFNULL(declined_page_views, 0) on every day.
WITH
  events AS (
    SELECT
      PARSE_DATE('%Y%m%d', event_date) AS day,
      event_name,
      privacy_info.analytics_storage = 'No' AS declined,
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
      COUNTIF(event_name IN ('page_view', 'screen_view')) AS page_views,
      COUNTIF(event_name IN ('page_view', 'screen_view') AND declined) AS declined_page_views
    FROM events
    GROUP BY day
  )
SELECT date AS day, active_users, sessions, screen_page_views AS page_views, CAST(NULL AS INT64) AS declined_page_views
FROM `${history}`
WHERE date < IFNULL((SELECT MIN(day) FROM export), DATE '9999-12-31')
UNION ALL
SELECT day, active_users, sessions, page_views, declined_page_views
FROM export

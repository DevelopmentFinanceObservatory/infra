-- The view dfo_reporting.ga4_pages_daily, a Terraform template
-- (reporting_views.tf): GA4 page views and sessions per day in the
-- property's reporting time zone and page path. Days from the GA4
-- BigQuery export's first day on come from ${events}, and days before it from
-- ${history}, as in ga4_daily.
--
-- The page path is the event's page_location with its scheme, host, query
-- string and fragment removed, as the Data API's pagePath holds it, and
-- (not set) for an event with no page_location. Sessions are distinct per
-- day and page, so they do not sum across pages. ga4_daily holds the day's
-- figures. A page's sessions sum across days, except that a session crossing
-- midnight counts on both days, so the sum runs slightly high.
WITH
  events AS (
    SELECT
      PARSE_DATE('%Y%m%d', event_date) AS day,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
      event_name,
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
      CASE
        WHEN page_location IS NULL THEN '(not set)'
        ELSE IFNULL(NULLIF(REGEXP_EXTRACT(page_location, r'^(?:[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*)?([^?#]*)'), ''), '/')
      END AS page_path,
      COUNTIF(event_name IN ('page_view', 'screen_view')) AS page_views,
      COUNT(DISTINCT session) AS sessions
    FROM events
    GROUP BY day, page_path
  )
SELECT date AS day, page_path, screen_page_views AS page_views, sessions
FROM `${history}`
WHERE date < IFNULL((SELECT MIN(day) FROM export), DATE '9999-12-31')
UNION ALL
SELECT day, page_path, page_views, sessions
FROM export

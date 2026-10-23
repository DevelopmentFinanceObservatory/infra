-- The view dfo_reporting.search_console_pages, a Terraform template
-- (reporting_views.tf): web-search clicks, impressions and position per day
-- in Pacific Time and page URL. Days from the bulk export's first day on come
-- from ${url_impressions}, its per-URL table, and days before it from
-- ${history}, as in search_console_daily.
--
-- url is the page URL with any query string and fragment removed, as the
-- history loader stores it, and the export's rows that then share a day and
-- url are summed, so a page's days do not split at the seam. All three
-- figures sum across rows. sum_position is the sum over impressions of the
-- page's position, with the top result as 0.
WITH
  export AS (
    SELECT
      data_date AS day,
      REGEXP_REPLACE(url, r'[?#].*$', '') AS url,
      SUM(clicks) AS clicks,
      SUM(impressions) AS impressions,
      SUM(sum_position) AS sum_position
    FROM `${url_impressions}`
    WHERE search_type = 'WEB'
    GROUP BY 1, 2
  )
SELECT date AS day, url, clicks, impressions, sum_position
FROM `${history}`
WHERE date < IFNULL((SELECT MIN(data_date) FROM `${url_impressions}`), DATE '9999-12-31')
UNION ALL
SELECT day, url, clicks, impressions, sum_position
FROM export

-- The view dfo_reporting.search_console_daily, a Terraform template
-- (reporting_views.tf): web-search clicks, impressions and position for the
-- whole property per day in Pacific Time, as Search Console reports days.
-- Days from the bulk export's first day on come from ${site_impressions},
-- its property-level table, and days before it from ${history}, which
-- scripts/load-search-console-history.sh fills from the Search Analytics
-- API. The seam is read from the export itself, so no day is counted twice.
--
-- sum_position is the sum over impressions of the property's top position,
-- with the top result as 0, on both sides of the seam, so it sums across
-- days and sum_position / impressions + 1 is the average position Search
-- Console shows. The export's rows per query, country and device all sum,
-- anonymised queries included.
WITH
  export AS (
    SELECT
      data_date AS day,
      SUM(clicks) AS clicks,
      SUM(impressions) AS impressions,
      SUM(sum_top_position) AS sum_position
    FROM `${site_impressions}`
    WHERE search_type = 'WEB'
    GROUP BY day
  )
SELECT date AS day, clicks, impressions, sum_position
FROM `${history}`
WHERE date < IFNULL((SELECT MIN(data_date) FROM `${site_impressions}`), DATE '9999-12-31')
UNION ALL
SELECT day, clicks, impressions, sum_position
FROM export

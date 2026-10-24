-- The date ranges the ga4-user-ranges workflow (ga4_user_ranges.tf) asks the
-- GA4 Data API for, batched into runReport request bodies. The workflow
-- passes @floor, the site's launch day; @today, today's date in the
-- property's time zone; and @first_data_day and @last_data_day, the
-- property's first and last days with data as the Data API's YYYYMMDD dates.
-- Every range ends no later than the data end, the earlier of yesterday and
-- the last day with data, since GA4 may not have processed yesterday yet:
--
--   since_floor  the floor through the data end
--   last_7       the 7 days ending at the data end
--   last_28      the 28 days ending at the data end
--   week         each ISO week (Monday to Sunday) from the floor's week
--   month        each calendar month from the floor's month
--
-- The current week and month end at the data end, and one that would start
-- after it is left out. No range is cut at the floor, so last_28 is always 28
-- days, as the dashboard's default window is, and the floor's month starts on
-- the 1st. A range that ends before the first day with data is left out too,
-- so GA4 has a row for every range asked for.
--
-- One row per request, at most four ranges each, the Data API's limit:
-- `ranges` lists each range's kind, start and end, and `request` is the
-- runReport body with their dateRanges in the same order, unnamed, so the
-- Data API labels them date_range_0 to date_range_3. The body sets
-- keepEmptyRows, since the Data API leaves out a row whose metrics are all
-- zero, and a range with no users still gets its row.
WITH
  bounds AS (
    SELECT
      @floor AS floor_day,
      LEAST(DATE_SUB(@today, INTERVAL 1 DAY), PARSE_DATE('%Y%m%d', @last_data_day)) AS data_end,
      PARSE_DATE('%Y%m%d', @first_data_day) AS first_data_day
  ),
  ranges AS (
    SELECT 0 AS kind_order, 'since_floor' AS range_kind, floor_day AS range_start, data_end AS range_end FROM bounds
    UNION ALL
    SELECT 1, 'last_7', DATE_SUB(data_end, INTERVAL 6 DAY), data_end FROM bounds
    UNION ALL
    SELECT 2, 'last_28', DATE_SUB(data_end, INTERVAL 27 DAY), data_end FROM bounds
    UNION ALL
    SELECT 3, 'week', week, LEAST(DATE_ADD(week, INTERVAL 6 DAY), data_end)
    FROM bounds, UNNEST(GENERATE_DATE_ARRAY(DATE_TRUNC(floor_day, ISOWEEK), data_end, INTERVAL 1 WEEK)) AS week
    UNION ALL
    SELECT 4, 'month', month, LEAST(LAST_DAY(month, MONTH), data_end)
    FROM bounds, UNNEST(GENERATE_DATE_ARRAY(DATE_TRUNC(floor_day, MONTH), data_end, INTERVAL 1 MONTH)) AS month
  ),
  requested AS (
    SELECT
      ranges.*,
      DIV(ROW_NUMBER() OVER (ORDER BY kind_order, range_start) - 1, 4) AS batch
    FROM ranges, bounds
    WHERE range_end >= first_data_day
  )
SELECT
  batch,
  TO_JSON_STRING(ARRAY_AGG(STRUCT(range_kind, range_start, range_end) ORDER BY kind_order, range_start)) AS ranges,
  TO_JSON_STRING(STRUCT(
    ARRAY_AGG(STRUCT(CAST(range_start AS STRING) AS startDate, CAST(range_end AS STRING) AS endDate) ORDER BY kind_order, range_start) AS dateRanges,
    [STRUCT('activeUsers' AS name), STRUCT('totalUsers' AS name), STRUCT('newUsers' AS name)] AS metrics,
    TRUE AS keepEmptyRows
  )) AS request
FROM requested
GROUP BY batch
ORDER BY batch

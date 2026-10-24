-- The rows of web_history.ga4_user_ranges from one run of the
-- ga4-user-ranges workflow (ga4_user_ranges.tf), which replaces the table
-- with them. @batches is a JSON array with one element per runReport call:
-- `ranges`, one row of sql/ga4_user_ranges_requests.sql, and `response`, the
-- Data API's reply to that row's request.
--
-- A reply to several dateRanges labels each row date_range_<n>, the range's
-- place in the request, and a reply to one range has no dateRange dimension,
-- so its row is date_range_0. Each metric value is a string, in the
-- request's order: activeUsers, totalUsers, newUsers. A range with no row or
-- more than one stops the query with an ERROR whose message starts
-- ga4_user_ranges:range_rows:, so the run writes nothing.
WITH
  batches AS (
    SELECT batch, b
    FROM UNNEST(JSON_QUERY_ARRAY(PARSE_JSON(@batches))) AS b WITH OFFSET AS batch
  ),
  ranges AS (
    SELECT
      batch,
      CONCAT('date_range_', CAST(n AS STRING)) AS date_range,
      JSON_VALUE(r, '$.range_kind') AS range_kind,
      DATE(JSON_VALUE(r, '$.range_start')) AS range_start,
      DATE(JSON_VALUE(r, '$.range_end')) AS range_end
    FROM batches, UNNEST(JSON_QUERY_ARRAY(b, '$.ranges')) AS r WITH OFFSET AS n
  ),
  report_rows AS (
    SELECT
      batch,
      IFNULL(JSON_VALUE(x, '$.dimensionValues[0].value'), 'date_range_0') AS date_range,
      CAST(JSON_VALUE(x, '$.metricValues[0].value') AS INT64) AS active_users,
      CAST(JSON_VALUE(x, '$.metricValues[1].value') AS INT64) AS total_users,
      CAST(JSON_VALUE(x, '$.metricValues[2].value') AS INT64) AS new_users
    FROM batches, UNNEST(JSON_QUERY_ARRAY(b, '$.response.rows')) AS x
  ),
  matched AS (
    SELECT
      r.batch,
      r.date_range,
      ANY_VALUE(r.range_kind) AS range_kind,
      ANY_VALUE(r.range_start) AS range_start,
      ANY_VALUE(r.range_end) AS range_end,
      COUNT(x.batch) AS matches,
      ANY_VALUE(x.active_users) AS active_users,
      ANY_VALUE(x.total_users) AS total_users,
      ANY_VALUE(x.new_users) AS new_users
    FROM ranges AS r
    LEFT JOIN report_rows AS x ON x.batch = r.batch AND x.date_range = r.date_range
    GROUP BY r.batch, r.date_range
  )
SELECT
  range_kind,
  range_start,
  range_end,
  IF(
    matches = 1,
    active_users,
    ERROR(FORMAT('ga4_user_ranges:range_rows: GA4 returned %d rows for %s %t to %t', matches, range_kind, range_start, range_end))
  ) AS active_users,
  total_users,
  new_users,
  CURRENT_TIMESTAMP() AS fetched_at
FROM matched

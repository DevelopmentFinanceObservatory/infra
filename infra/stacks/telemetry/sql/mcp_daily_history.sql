-- mcp_daily's whole days from the day after the staged copy's oldest stdout
-- or stderr entry through the cut-off day, which scripts/load-logs-backfill.sh writes as one BigQuery
-- script before it replaces backfill_entries. The "Backfill" section of
-- infra/dfo-prod/telemetry/README.md says why the loader and the scheduled
-- query each write part of mcp_daily, and what a rebuild of the loader's days
-- needs. The loader fills the placeholders: dataset with logs_daily,
-- live_source with dfo_logs._AllLogs, parse_mcp_line with the
-- logs_daily.parse_mcp_line function (sql/parse_mcp_line.sql), cutoff with
-- infra/stacks/telemetry/logs_backfill_cutoff.txt, and backfill with
-- sql/backfill_entries.sql over the staged copy.
--
-- The script reads the staged copy once into a temp table, with the message
-- of the combined MCP server's lines only and no other column the step does
-- not read, and counts its entries before the cut-off and dfo_logs from the
-- cut-off to the end of that day, the entries the logs_daily.entries view
-- holds for those days. The parse reads the stdout and stderr logs of
-- cloud_run_revision, and the copy cut entries part way through the oldest
-- day of those logs, so that day is partial and the range starts the day
-- after it, whatever day the requests folder starts. The DELETE and the
-- INSERT both cover that range and no other, so a rerun from a copy that
-- starts later leaves the days before it as they are. The messages exist only
-- inside the script, and mcp_daily holds no caller outside callers_sketch.
-- The script drops its three temp tables, which hold MCP lines with their
-- callers, after the COMMIT. A run that fails first leaves them to expire with
-- the script's session within 24 hours.
--
-- The script assumes the copy runs to the cut-off, as backfill_entries does.
-- It checks only that the copy's newest stdout or stderr entry is no older
-- than dfo_logs' oldest entry, so a copy that stops between dfo_logs' oldest
-- entry and the cut-off leaves those minutes uncounted.
--
-- Each refusal is an ASSERT whose message starts with a code,
-- mcp_history:<code>:. sql/mcp_daily_preflight.sql, which the loader runs
-- before it loads staging, refuses with no_mcp_daily and
-- dfo_logs_after_cutoff. This script checks dfo_logs_after_cutoff again
-- before any write, since the retention of dfo_logs can move between the two.
-- It also refuses, before any write, with copy_after_cutoff when staging
-- holds no stdout or stderr entry before the cut-off, with no_whole_day when
-- those logs cover no whole day before the cut-off, with copy_ends_early
-- when the copy's newest entry of those logs is older than dfo_logs' oldest
-- entry, and with no_mcp_call when the staged entries before the cut-off hold
-- no line the parse accepts. Inside the transaction, after the INSERT, it
-- fails and rolls back with fewer_calls when any day ends with fewer calls
-- than before, so a rerun never lowers a day's calls. A first load, with no
-- rows in the range, writes whatever the copy holds. It ends with the MCP
-- calls it wrote per day, over the range it replaced and no other day, each
-- row marked mcp_history_day so the loader counts those rows alone.

DECLARE live_first TIMESTAMP DEFAULT (SELECT MIN(timestamp) FROM `${live_source}`);
DECLARE staged_first, staged_last TIMESTAMP;
DECLARE first_whole_day DATE;

ASSERT live_first <= TIMESTAMP '${cutoff}'
AS 'mcp_history:dfo_logs_after_cutoff: dfo_logs holds no entry from before the cut-off, so the cut-off day would load partial.';

CREATE TEMP TABLE staged AS
SELECT
  timestamp,
  log_id,
  resource_type,
  logger,
  IF(logger = 'harness.combined_mcp', JSON_VALUE(message), NULL) AS message
FROM (
  SELECT
    timestamp,
    log_id,
    resource.type AS resource_type,
    JSON_VALUE(json_payload.logger) AS logger,
    message
  FROM (
${backfill}
  )
)
WHERE resource_type = 'cloud_run_revision'
  AND log_id IN ('run.googleapis.com/stdout', 'run.googleapis.com/stderr');

SET (staged_first, staged_last) = (SELECT AS STRUCT MIN(timestamp), MAX(timestamp) FROM staged);
ASSERT staged_first < TIMESTAMP '${cutoff}'
AS 'mcp_history:copy_after_cutoff: the staged copy holds no stdout or stderr entry from before the cut-off, so no whole day would load.';
SET first_whole_day = DATE(staged_first) + 1;
ASSERT first_whole_day <= DATE(TIMESTAMP '${cutoff}')
AS 'mcp_history:no_whole_day: the staged stdout and stderr entries cover no whole day before the cut-off; their oldest day is partial.';
ASSERT staged_last >= live_first
AS 'mcp_history:copy_ends_early: the staged copy ends before dfo_logs begins, so the minutes between them would load empty.';

CREATE TEMP TABLE mcp_calls AS
SELECT timestamp, mcp
FROM (
  SELECT timestamp, `${parse_mcp_line}`(message) AS mcp
  FROM (
    SELECT timestamp, log_id, resource_type, logger, message
    FROM staged
    WHERE timestamp >= TIMESTAMP(first_whole_day)
      AND timestamp < TIMESTAMP '${cutoff}'
    UNION ALL
    SELECT timestamp, log_id, resource.type, JSON_VALUE(json_payload.logger), JSON_VALUE(json_payload.message)
    FROM `${live_source}`
    WHERE timestamp >= TIMESTAMP '${cutoff}'
      AND timestamp < TIMESTAMP(DATE(TIMESTAMP '${cutoff}') + 1)
  )
  WHERE resource_type = 'cloud_run_revision'
    AND log_id IN ('run.googleapis.com/stdout', 'run.googleapis.com/stderr')
    AND logger = 'harness.combined_mcp'
)
WHERE mcp IS NOT NULL;

-- Only the staged side is before the cut-off, so a dfo_logs line cannot
-- satisfy this.
ASSERT EXISTS (
  SELECT 1 FROM mcp_calls WHERE timestamp < TIMESTAMP '${cutoff}'
) AS 'mcp_history:no_mcp_call: the staged entries before the cut-off hold no MCP call line; nothing changed.';

CREATE TEMP TABLE mcp_calls_before AS
SELECT day, SUM(calls) AS calls
FROM `${dataset}.mcp_daily`
WHERE day BETWEEN first_whole_day AND DATE(TIMESTAMP '${cutoff}')
GROUP BY day;

BEGIN TRANSACTION;

DELETE FROM `${dataset}.mcp_daily`
WHERE day BETWEEN first_whole_day AND DATE(TIMESTAMP '${cutoff}');
INSERT INTO `${dataset}.mcp_daily`
SELECT
  DATE(timestamp),
  mcp.caller_kind,
  mcp.client,
  mcp.request,
  mcp.outcome,
  COUNT(*),
  HLL_COUNT.INIT(mcp.caller, 14)
FROM mcp_calls
GROUP BY 1, 2, 3, 4, 5;

ASSERT NOT EXISTS (
  SELECT 1
  FROM mcp_calls_before AS b
  LEFT JOIN (
    SELECT day, SUM(calls) AS calls
    FROM `${dataset}.mcp_daily`
    WHERE day BETWEEN first_whole_day AND DATE(TIMESTAMP '${cutoff}')
    GROUP BY day
  ) AS a USING (day)
  WHERE IFNULL(a.calls, 0) < b.calls
) AS 'mcp_history:fewer_calls: the staged copy yields fewer MCP calls than mcp_daily holds on some day; nothing changed.';

COMMIT TRANSACTION;

DROP TABLE mcp_calls_before;
DROP TABLE mcp_calls;
DROP TABLE staged;

SELECT 'mcp_history_day' AS marker, day, SUM(calls) AS calls
FROM `${dataset}.mcp_daily`
WHERE day BETWEEN first_whole_day AND DATE(TIMESTAMP '${cutoff}')
GROUP BY day
ORDER BY day;

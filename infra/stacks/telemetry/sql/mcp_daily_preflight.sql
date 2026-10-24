-- The checks of scripts/load-logs-backfill.sh's mcp_daily step that need no
-- staged copy, which the loader runs before it loads staging so that a
-- refusal costs no load. Each is an ASSERT whose message starts with a code,
-- mcp_history:<code>:, as in sql/mcp_daily_history.sql, which lists the
-- refusals that need the copy. The loader fills the placeholders: dataset
-- with logs_daily, live_source with dfo_logs._AllLogs, and cutoff with
-- infra/stacks/telemetry/logs_backfill_cutoff.txt.
--
-- no_mcp_daily refuses when mcp_daily does not exist, since the scheduled
-- query creates it on its first run. dfo_logs_after_cutoff refuses when
-- dfo_logs no longer reaches back to the cut-off, since the cut-off day would
-- load partial.

ASSERT EXISTS (
  SELECT 1 FROM `${dataset}.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'mcp_daily'
) AS 'mcp_history:no_mcp_daily: logs_daily.mcp_daily does not exist; run the logs_daily scheduled query once first.';
ASSERT (SELECT MIN(timestamp) FROM `${live_source}`) <= TIMESTAMP '${cutoff}'
AS 'mcp_history:dfo_logs_after_cutoff: dfo_logs holds no entry from before the cut-off, so the cut-off day would load partial.';

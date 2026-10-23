#!/usr/bin/env bash
# Tests sql/backfill_entries.sql against LogEntry rows shaped as
# scripts/load-logs-backfill.sh stages them, with jsonPayload cut to logger
# and message. Not wired into CI. Run by hand after touching the query:
#   infra/stacks/telemetry/tests/backfill_entries.test.sh [project]
#
# The staging table is a CTE of literal rows, so the query reads no table and
# scans no bytes. The project (default prod-fin-observatory) only bills and
# runs the job, and the caller needs bigquery.jobs.create on it. Each output
# row prints as JSON in timestamp order and must match WANT exactly.
set -euo pipefail

PROJECT="${1:-prod-fin-observatory}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECT="$(cat "$DIR/../sql/backfill_entries.sql")"
# shellcheck disable=SC2016 # the patterns are the template's literal placeholders
SELECT="${SELECT//'${staging}'/staging}"
# shellcheck disable=SC2016
SELECT="${SELECT//'${namespace}'/dfo-prod}"

# One row per case, each named by its insertId:
#   req: a request with nanosecond timestamp and latency, kept.
#   req-dup: the same entry copied twice, kept once.
#   req-whole: a whole-second latency, kept.
#   req-nolatency: a request with no latency, kept with a NULL latency.
#   stdout-default: no severity, kept as DEFAULT, message dropped.
#   job-warning: a job's stderr with no logger, kept with a NULL json_payload.
#   website-event: the website's usage-event line, dropped.
#   website-plain: a website stdout line with no message field, kept.
#   api-event: another service's "event" message, kept.
#   varlog: a log id the sink does not route, dropped.
#   gce: a resource type the sink does not route, dropped.
STAGING="WITH staging AS (
  SELECT * FROM UNNEST(ARRAY<STRUCT<
    timestamp STRING, logName STRING, insertId STRING, severity STRING,
    resource STRUCT<type STRING, labels JSON>,
    httpRequest STRUCT<requestMethod STRING, requestUrl STRING, status INT64, latency STRING>,
    jsonPayload STRUCT<logger JSON, message JSON>>>[
  ('2026-10-01T10:00:00.123456789Z', 'projects/p/logs/run.googleapis.com%2Frequests', 'req', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\", \"revision_name\": \"dfo-prod-api-00001-abc\"}'),
    ('GET', 'https://api.example.org/v1/x?q=1', 200, '0.123456789s'), NULL),
  ('2026-10-01T10:00:00.123456789Z', 'projects/p/logs/run.googleapis.com%2Frequests', 'req', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\", \"revision_name\": \"dfo-prod-api-00001-abc\"}'),
    ('GET', 'https://api.example.org/v1/x?q=1', 200, '0.123456789s'), NULL),
  ('2026-10-01T10:00:01Z', 'projects/p/logs/run.googleapis.com%2Frequests', 'req-whole', 'ERROR',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    ('POST', 'https://api.example.org/v1/y', 503, '12s'), NULL),
  ('2026-10-01T10:00:02Z', 'projects/p/logs/run.googleapis.com%2Frequests', 'req-nolatency', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    ('GET', 'https://api.example.org/', 302, NULL), NULL),
  ('2026-10-01T10:00:03Z', 'projects/p/logs/run.googleapis.com%2Fstdout', 'stdout-default', NULL,
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    NULL, (JSON '\"uvicorn\"', JSON '\"secret text\"')),
  ('2026-10-01T10:00:04Z', 'projects/p/logs/run.googleapis.com%2Fstderr', 'job-warning', 'WARNING',
    ('cloud_run_job', JSON '{\"job_name\": \"dfo-prod-export\"}'),
    NULL, (NULL, JSON '\"slow\"')),
  ('2026-10-01T10:00:05Z', 'projects/p/logs/run.googleapis.com%2Fstdout', 'website-event', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-website\"}'),
    NULL, (NULL, JSON '\"event\"')),
  ('2026-10-01T10:00:06Z', 'projects/p/logs/run.googleapis.com%2Fstdout', 'website-plain', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-website\"}'),
    NULL, NULL),
  ('2026-10-01T10:00:07Z', 'projects/p/logs/run.googleapis.com%2Fstdout', 'api-event', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    NULL, (JSON '\"app\"', JSON '\"event\"')),
  ('2026-10-01T10:00:08Z', 'projects/p/logs/run.googleapis.com%2Fvarlog%2Fsystem', 'varlog', 'INFO',
    ('cloud_run_revision', JSON '{\"service_name\": \"dfo-prod-api\"}'),
    NULL, NULL),
  ('2026-10-01T10:00:09Z', 'projects/p/logs/run.googleapis.com%2Fstdout', 'gce', 'INFO',
    ('gce_instance', JSON '{\"instance_id\": \"1\"}'),
    NULL, NULL)
  ])
)"

QUERY="$STAGING
SELECT TO_JSON_STRING(t) AS row FROM (
$SELECT
) AS t
ORDER BY t.timestamp"

WANT='{"timestamp":"2026-10-01T10:00:00.123456Z","log_id":"run.googleapis.com/requests","severity":"INFO","resource":{"type":"cloud_run_revision","labels":{"revision_name":"dfo-prod-api-00001-abc","service_name":"dfo-prod-api"}},"http_request":{"request_method":"GET","request_url":"https://api.example.org/v1/x?q=1","status":200,"latency":{"seconds":0,"nanos":123456789}},"json_payload":null}
{"timestamp":"2026-10-01T10:00:01Z","log_id":"run.googleapis.com/requests","severity":"ERROR","resource":{"type":"cloud_run_revision","labels":{"service_name":"dfo-prod-api"}},"http_request":{"request_method":"POST","request_url":"https://api.example.org/v1/y","status":503,"latency":{"seconds":12,"nanos":0}},"json_payload":null}
{"timestamp":"2026-10-01T10:00:02Z","log_id":"run.googleapis.com/requests","severity":"INFO","resource":{"type":"cloud_run_revision","labels":{"service_name":"dfo-prod-api"}},"http_request":{"request_method":"GET","request_url":"https://api.example.org/","status":302,"latency":null},"json_payload":null}
{"timestamp":"2026-10-01T10:00:03Z","log_id":"run.googleapis.com/stdout","severity":"DEFAULT","resource":{"type":"cloud_run_revision","labels":{"service_name":"dfo-prod-api"}},"http_request":null,"json_payload":{"logger":"uvicorn"}}
{"timestamp":"2026-10-01T10:00:04Z","log_id":"run.googleapis.com/stderr","severity":"WARNING","resource":{"type":"cloud_run_job","labels":{"job_name":"dfo-prod-export"}},"http_request":null,"json_payload":null}
{"timestamp":"2026-10-01T10:00:06Z","log_id":"run.googleapis.com/stdout","severity":"INFO","resource":{"type":"cloud_run_revision","labels":{"service_name":"dfo-prod-website"}},"http_request":null,"json_payload":null}
{"timestamp":"2026-10-01T10:00:07Z","log_id":"run.googleapis.com/stdout","severity":"INFO","resource":{"type":"cloud_run_revision","labels":{"service_name":"dfo-prod-api"}},"http_request":null,"json_payload":{"logger":"app"}}'

GOT="$(bq query --project_id="$PROJECT" --location=EU --use_legacy_sql=false \
    --format=csv --max_rows=1000 "$QUERY" | tail -n +2 | sed 's/^"//;s/"$//;s/""/"/g')"

if [ "$GOT" != "$WANT" ]; then
    echo "backfill_entries.test.sh: output differs from WANT (- want, + got):" >&2
    diff <(echo "$WANT") <(echo "$GOT") >&2 || true
    exit 1
fi
echo "backfill_entries.test.sh: $(wc -l <<<"$WANT" | tr -d ' ') rows match"

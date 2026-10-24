-- Body of the logs_daily.parse_mcp_line(message STRING) function, the parse
-- of the combined MCP server's per-call log lines that every writer of
-- mcp_daily calls: sql/logs_daily.sql and sql/mcp_daily_history.sql. It
-- returns NULL for a message that is not a call line, and otherwise the
-- row's request, outcome, caller kind and client, as mcp_daily stores them,
-- and the raw caller for callers_sketch, NULL when the line names none.
--
-- mcp_line matches a combined MCP line, with the call's request in group 1,
-- outcome in 2 and caller in 3, or initialize in 4, its outcome in 5 and
-- caller in 6, and the client in 7. The caller is matched lazily up to the
-- fixed field after it, since a header value may hold spaces. A line that
-- starts "combined mcp " in any other shape gives request 'unparsed', with
-- outcome, caller kind and client 'none' and no caller. The server's
-- warnings start "combined mcp: " and are not calls.
-- tests/mcp_daily.test.sh runs this file over literal lines in each shape.
(
  SELECT AS STRUCT
    CASE
      WHEN NOT STARTS_WITH(request, 'tool=') THEN request
      WHEN REGEXP_CONTAINS(SUBSTR(request, 6), r'^[A-Za-z0-9_.-]{1,64}$') THEN SUBSTR(request, 6)
      ELSE 'other'
    END AS request,
    IF(REGEXP_CONTAINS(outcome, r'^[A-Za-z0-9_.-]{1,64}$'), outcome, 'other') AS outcome,
    CASE
      WHEN caller = 'None' THEN 'none'
      ELSE IFNULL(REGEXP_EXTRACT(caller, r'^(user|key|ip|conversation):'), 'other')
    END AS caller_kind,
    CASE
      WHEN client = 'None' THEN 'none'
      WHEN REGEXP_CONTAINS(JSON_VALUE(client), r'^[A-Za-z0-9 ._/-]{1,64}$') THEN JSON_VALUE(client)
      ELSE 'other'
    END AS client,
    NULLIF(caller, 'None') AS caller
  FROM (
    SELECT
      IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\1\4'), 'unparsed') AS request,
      IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\2\5'), 'none') AS outcome,
      IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\3\6'), 'None') AS caller,
      IF(parsed, REGEXP_REPLACE(message, mcp_line, r'\7'), 'None') AS client
    FROM (
      SELECT mcp_line, REGEXP_CONTAINS(message, mcp_line) AS parsed
      FROM (
        SELECT r'(?s)^combined mcp (?:call (tool=(?:[A-Za-z0-9_.-]+|"(?:[^"\\]|\\.)*")|resource|resource_list) outcome=(.*?) revision=\S* caller=(.*?) trace_id=\S*|(initialize) outcome=(.*?) revision=\S* caller=(.*?)) client=(None|"(?:[^"\\]|\\.)*") client_version=.*$' AS mcp_line
      )
    )
  )
  WHERE STARTS_WITH(message, 'combined mcp ')
)

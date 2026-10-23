-- Body of the logs_daily.normalise_route(url STRING) function. Cloud Run
-- request logs carry the requested URL and no route template, so routes are
-- recovered from the path's shape. The scheme, host, query string, fragment
-- and trailing slashes go. Everything under /_next/static/ is content-hashed
-- build output and becomes /_next/static/:asset. Any other segment becomes
-- :id when it starts with a digit, holds an upper-case letter, is a UUID, or
-- holds a digit with no hyphen or dot. That covers numbers, versions such as
-- 1.0.0, hex digests, sha256:<hex> file ids, prefixed ids such as spec_<hex>
-- and cmp_<ULID>, share ids, and dcids. API versions such as v1 stay, and so
-- do lower-case words, hyphenated slugs and file names.
-- tests/normalise_route.test.sh runs this file against recorded prod URLs.
(
  SELECT
    CASE
      WHEN path IS NULL THEN NULL
      WHEN path = '' THEN '/'
      WHEN STARTS_WITH(path, '/_next/static/') THEN '/_next/static/:asset'
      ELSE ARRAY_TO_STRING(
        ARRAY(
          SELECT
            CASE
              WHEN REGEXP_CONTAINS(segment, r'^v[0-9]+$') THEN segment
              WHEN REGEXP_CONTAINS(segment, r'^[0-9]') THEN ':id'
              WHEN REGEXP_CONTAINS(segment, r'[A-Z]') THEN ':id'
              WHEN REGEXP_CONTAINS(segment, r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN ':id'
              WHEN REGEXP_CONTAINS(segment, r'[0-9]') AND NOT REGEXP_CONTAINS(segment, r'[-.]') THEN ':id'
              ELSE segment
            END
          FROM UNNEST(SPLIT(path, '/')) AS segment WITH OFFSET AS position
          ORDER BY position
        ),
        '/'
      )
    END
  FROM (
    SELECT RTRIM(REGEXP_EXTRACT(url, r'^(?:[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*)?([^?#]*)'), '/') AS path
  )
)

-- The view dfo_reporting.website_page_views_daily, a Terraform template
-- (reporting_views.tf): the website's page views per UTC day, from people
-- and from bots. Days from the website request log's first parsed day on
-- come from ${website_requests_daily}, and days before it from ${history},
-- which scripts/load-website-page-history.sh fills with page views rebuilt
-- from Cloud Run's request log. The seam is read from the website request
-- log itself, so no day is counted twice whatever range the history holds.
--
-- A page view is a request of kind 'page' answered 2xx. page_views counts
-- those the website did not judge to come from a bot, and bot_page_views
-- those it did. The history judges with the website's isbot release and
-- counts a request with no user agent as a bot.
--
-- The request log's first parsed day is its first day with a row other than
-- 'unparsed'. The lines written before the log gained its status and bot
-- fields count as unparsed, so a day holding only those keeps its history
-- row. A later day holding only unparsed rows has no row, since its page
-- views are unknown.
WITH
  log AS (
    SELECT
      day,
      SUM(IF(kind = 'page' AND status_class = 2 AND NOT bot, requests, 0)) AS page_views,
      SUM(IF(kind = 'page' AND status_class = 2 AND bot, requests, 0)) AS bot_page_views
    FROM `${website_requests_daily}`
    WHERE kind != 'unparsed'
    GROUP BY day
  )
SELECT date AS day, page_views, bot_page_views
FROM `${history}`
WHERE date < IFNULL((SELECT MIN(day) FROM log), DATE '9999-12-31')
UNION ALL
SELECT day, page_views, bot_page_views
FROM log

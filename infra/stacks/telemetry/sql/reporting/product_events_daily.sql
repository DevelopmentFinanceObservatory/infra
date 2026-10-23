-- The view dfo_reporting.product_events_daily, a Terraform template
-- (reporting_views.tf): website product events per UTC day of created_at,
-- event name, page and signed-in state, from ${events}, the website export's
-- copy of the Postgres event table. page is ${normalise_route}(page), the
-- path with its ids written :id, so conversation, share and other ids in
-- paths such as /studio/<id> do not reach readers.
--
-- visitors_sketch and users_sketch are HLL++ sketches of the export's
-- visitor_hash and user_hash. Only signed-in events carry a user_hash. Distinct
-- counts do not sum across rows, so a reader merges the sketches of the rows
-- it wants with HLL_COUNT.MERGE, over any pages, events or days, and no
-- hashed id reaches readers.
SELECT
  day,
  name AS event,
  page,
  signed_in,
  COUNT(*) AS events,
  HLL_COUNT.INIT(visitor_hash, 14) AS visitors_sketch,
  HLL_COUNT.INIT(user_hash, 14) AS users_sketch
FROM (
  SELECT
    DATE(created_at) AS day,
    name,
    `${normalise_route}`(page) AS page,
    signed_in,
    visitor_hash,
    user_hash
  FROM `${events}`
)
GROUP BY day, name, page, signed_in

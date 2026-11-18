-- The view dfo_reporting.cloudflare_pages_daily, a Terraform template
-- (reporting_views.tf): Cloudflare page loads per UTC day and path from
-- ${history}, which scripts/load-cloudflare-pages-history.sh fills from a
-- capture of Cloudflare's request analytics. page_loads counts eyeball GET
-- requests for the path answered 200 with HTML on developmentfinance.org and
-- www from no verified bot, and verified_bot_page_loads those from verified
-- bots. They cover pages GA4 does not, such as the prototypes app under
-- /prototypes, for the days before the website's GA4 tag loads there.
SELECT date AS day, path, page_loads, verified_bot_page_loads
FROM `${history}`

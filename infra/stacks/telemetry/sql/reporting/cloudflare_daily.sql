-- The view dfo_reporting.cloudflare_daily, a Terraform template
-- (reporting_views.tf): Cloudflare page loads per UTC day from ${history},
-- which scripts/load-cloudflare-history.sh fills from a capture of
-- Cloudflare's request analytics. page_loads counts eyeball GET requests
-- answered 200 with HTML on developmentfinance.org and www from no verified
-- bot, and verified_bot_page_loads those from verified bots. They cover every
-- visitor, whatever their consent, for the days before the website's request
-- log records status and bot fields.
SELECT date AS day, page_loads, verified_bot_page_loads
FROM `${history}`

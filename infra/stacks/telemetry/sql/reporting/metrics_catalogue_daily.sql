-- The view dfo_reporting.metrics_catalogue_daily, a Terraform template
-- (reporting_views.tf) over the analytics dbt marts. Grain: day. The search
-- catalogue live at each complete day's end. Indicators are variables.
SELECT
  c.day,
  c.catalogue_version,
  c.sources,
  c.datasets,
  c.indicators,
  c.dfo_sources,
  c.dfo_datasets,
  c.dfo_indicators,
  c.data_commons_sources,
  c.data_commons_datasets,
  c.data_commons_indicators
FROM `${catalogue_daily}` AS c
WHERE c.day < CURRENT_DATE()

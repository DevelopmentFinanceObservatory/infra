-- The view dfo_reporting.model_spend_daily, a Terraform template
-- (reporting_views.tf): Cloud Billing cost per UTC day of usage_start_time,
-- caller, service, SKU and currency, from ${billing}, the standard usage
-- cost export. The billing account also bills projects outside DFO, so only
-- the projects in the spend_callers variable are kept, each labelled with its
-- caller: ${callers}.
--
-- Cloud Billing keeps adding cost to a day for about a day after it ends,
-- so the view keeps only days before yesterday, and every day it holds is
-- whole.
--
-- cost is before credits, credits is the sum of the rows' credit amounts,
-- which are negative, and net_cost is cost plus credits. Every cost type is
-- summed, tax and adjustments included.
SELECT
  DATE(billing.usage_start_time) AS day,
  callers.caller,
  billing.service.description AS service,
  billing.sku.description AS sku,
  SUM(billing.cost) AS cost,
  SUM(IFNULL((SELECT SUM(credit.amount) FROM UNNEST(billing.credits) AS credit), 0)) AS credits,
  SUM(billing.cost)
    + SUM(IFNULL((SELECT SUM(credit.amount) FROM UNNEST(billing.credits) AS credit), 0)) AS net_cost,
  billing.currency
FROM `${billing}` AS billing
INNER JOIN UNNEST(ARRAY<STRUCT<project_id STRING, caller STRING>>[${callers}]) AS callers
  ON billing.project.id = callers.project_id
WHERE DATE(billing.usage_start_time) < CURRENT_DATE() - 1
GROUP BY 1, 2, 3, 4, 8

-- The view billing_dfo.costs, a Terraform template (analytics.tf): one row
-- per Cloud Billing usage cost line from ${billing}, the standard usage cost
-- export. The billing account also bills projects outside DFO, so only the
-- projects in the spend_callers variable are kept, each labelled with its
-- caller: ${callers}.
--
-- credits is the sum of the line's credit amounts, which are negative, and 0
-- for a line with none.
SELECT
  callers.caller,
  billing.project.id AS project_id,
  billing.service.description AS service,
  billing.sku.description AS sku,
  billing.usage_start_time,
  billing.export_time,
  billing.cost,
  billing.currency,
  IFNULL((SELECT SUM(credit.amount) FROM UNNEST(billing.credits) AS credit), 0) AS credits
FROM `${billing}` AS billing
INNER JOIN UNNEST(ARRAY<STRUCT<project_id STRING, caller STRING>>[${callers}]) AS callers
  ON billing.project.id = callers.project_id

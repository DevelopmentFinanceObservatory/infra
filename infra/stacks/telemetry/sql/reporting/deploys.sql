-- The view dfo_reporting.deploys, a Terraform template (reporting_views.tf):
-- each Cloud Run revision deployed while the logs source ran, timed at its
-- first request. ${deploys} also records the revisions already serving when
-- the source began, with before_source true, whose first request is not a
-- deploy, and this view leaves them out.
SELECT
  service,
  revision,
  first_request AS deployed_at
FROM `${deploys}`
WHERE NOT before_source

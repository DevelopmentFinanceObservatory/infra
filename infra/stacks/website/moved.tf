# Maps the website_staging_* addresses dfo-dev's state holds to the tier-neutral ones.
# dfo-prod's state has nothing at the old addresses, so these are no-ops there.

moved {
  from = module.website_staging_service
  to   = module.website_service
}

moved {
  from = google_secret_manager_secret.website_staging_better_auth_secret
  to   = google_secret_manager_secret.website_better_auth_secret
}

moved {
  from = google_secret_manager_secret_version.website_staging_better_auth_secret
  to   = google_secret_manager_secret_version.website_better_auth_secret
}

moved {
  from = google_secret_manager_secret.website_staging_caller_hmac_key
  to   = google_secret_manager_secret.website_caller_hmac_key
}

moved {
  from = google_secret_manager_secret_version.website_staging_caller_hmac_key
  to   = google_secret_manager_secret_version.website_caller_hmac_key
}

moved {
  from = google_secret_manager_secret.website_staging_feedback_slack_webhook
  to   = google_secret_manager_secret.website_feedback_slack_webhook
}

moved {
  from = google_secret_manager_secret_version.website_staging_feedback_slack_webhook_placeholder
  to   = google_secret_manager_secret_version.website_feedback_slack_webhook_placeholder
}

moved {
  from = google_sql_database.website_staging
  to   = google_sql_database.website
}

moved {
  from = google_sql_user.website_staging_runtime
  to   = google_sql_user.website_runtime
}

moved {
  from = google_project_iam_member.website_cloudsql_client["staging"]
  to   = google_project_iam_member.website_cloudsql_client
}

moved {
  from = google_project_iam_member.website_cloudsql_login["staging"]
  to   = google_project_iam_member.website_cloudsql_login
}

moved {
  from = google_service_account.website_staging_migrator
  to   = google_service_account.website_migrator
}

moved {
  from = google_sql_user.website_staging_migrator
  to   = google_sql_user.website_migrator
}

moved {
  from = google_project_iam_member.website_staging_migrator_cloudsql_client
  to   = google_project_iam_member.website_migrator_cloudsql_client
}

moved {
  from = google_project_iam_member.website_staging_migrator_cloudsql_login
  to   = google_project_iam_member.website_migrator_cloudsql_login
}

moved {
  from = google_sql_provision_script.website_staging_db_acl
  to   = google_sql_provision_script.website_db_acl
}

moved {
  from = google_sql_provision_script.website_staging_db_schema_grant
  to   = google_sql_provision_script.website_db_schema_grant
}

moved {
  from = google_cloud_run_v2_job.website_staging_migrate
  to   = google_cloud_run_v2_job.website_migrate
}

moved {
  from = google_cloud_run_v2_job_iam_member.website_staging_migrate_deployer_run_developer
  to   = google_cloud_run_v2_job_iam_member.website_migrate_deployer_run_developer
}

moved {
  from = google_service_account_iam_member.website_migrator_staging_deployer_act_as
  to   = google_service_account_iam_member.website_migrator_deployer_act_as
}

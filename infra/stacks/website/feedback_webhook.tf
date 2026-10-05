# The Slack incoming webhook the website's feedback endpoint posts each
# submission to (dfo-website /api/feedback). Slack issues the URL, so its
# value can't be generated here the way the auth secret is: Terraform owns
# the secret container and the mount, and the values are added out-of-band
# as new versions (see README.md, "Feedback Slack webhook"). Revoking a
# leaked webhook in Slack and adding the reissued URL as a new version is
# the whole rotation story; no Terraform change is involved.

resource "google_secret_manager_secret" "website_feedback_slack_webhook" {
  secret_id = "${local.website_name}-feedback-slack-webhook"

  replication {
    auto {}
  }
}

# Cloud Run fails to start a revision whose secret env var can't be
# resolved, and the mount tracks `latest`, so the secret must never be
# versionless. This placeholder guarantees that between this stack applying
# and the first real URL being added; the app treats any value that isn't a
# Slack webhook URL as "notifications off". Real versions added out-of-band
# immediately become `latest` and win. The literal is not sensitive, so a
# plain (state-visible) version is fine here.
resource "google_secret_manager_secret_version" "website_feedback_slack_webhook_placeholder" {
  secret      = google_secret_manager_secret.website_feedback_slack_webhook.id
  secret_data = "disabled"
}

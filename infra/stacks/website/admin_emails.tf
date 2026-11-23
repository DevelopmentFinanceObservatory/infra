# The admins of the website's admin page (/admin/api-keys): the
# comma-separated emails of the signed-in users, with a verified email, who
# may open it (ADMIN_EMAILS). The list is private and this repository is
# public, so the value can't live in Terraform. Terraform owns the secret
# container and the mount, and the real list is added out-of-band as a new
# version (see README.md, "Admin emails"). The mount reads `latest`, so a new
# version reaches every instance that starts after it, on autoscale or
# restart, and a label roll brings the running instances onto it. No
# Terraform change is involved.

resource "google_secret_manager_secret" "website_admin_emails" {
  secret_id = "${local.website_name}-admin-emails"

  replication {
    auto {}
  }
}

# Cloud Run fails to start a revision whose secret env var can't be
# resolved, and the mount tracks `latest`, so the secret must never be
# versionless. This placeholder guarantees that between this stack applying
# and the real list being added. The app splits the value on commas and
# compares each entry with a signed-in user's verified email, and `none` is
# not an email address, so it admits nobody and /admin/api-keys answers 404.
# Real versions added out-of-band immediately become `latest` and win. The
# literal is not sensitive, so a plain (state-visible) version is fine here.
resource "google_secret_manager_secret_version" "website_admin_emails_placeholder" {
  secret      = google_secret_manager_secret.website_admin_emails.id
  secret_data = "none"

  # A recreated placeholder becomes the newest version, which the mount reads,
  # and drops every admin.
  lifecycle {
    prevent_destroy = true
  }
}

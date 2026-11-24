# The admins of the website's admin page (/admin/api-keys): the
# comma-separated emails of the signed-in users, with a verified email, who
# may open it (ADMIN_EMAILS). The list is private and this repository is
# public, so the value can't live in Terraform. Terraform owns the secret
# container and the mount, and the real list is added out-of-band as a new
# version (see README.md, "Admin emails"). The mount is pinned to
# var.admin_emails_version, so a new version reaches instances only through
# the revision that the apply of a new pin creates. Each new admin then gets
# a reviewed pull request, and the pin, a version number, reveals no address.

resource "google_secret_manager_secret" "website_admin_emails" {
  secret_id = "${local.website_name}-admin-emails"

  replication {
    auto {}
  }
}

# Version 1, which var.admin_emails_version starts at. Cloud Run fails to
# start a revision whose secret env var can't be resolved, so the first apply
# needs a version to pin before the real list exists. The app splits the
# value on commas and compares each entry with a signed-in user's verified
# email, and `none` is not an email address, so it admits nobody and
# /admin/api-keys answers 404. The literal is not sensitive, so a plain
# (state-visible) version is fine here.
resource "google_secret_manager_secret_version" "website_admin_emails_placeholder" {
  secret      = google_secret_manager_secret.website_admin_emails.id
  secret_data = "none"

  # A replacement would get a new version number and destroy version 1,
  # which a pin of "1" still names, so no new revision could start.
  # prevent_destroy covers Terraform's plans only, so never destroy or
  # disable the version by hand either (see README.md, "Admin emails").
  lifecycle {
    prevent_destroy = true
  }
}

# The engineering accounts whose events the website flags `internal_eng`
# (INTERNAL_ENG_EMAILS), so analytics can leave them out of usage metrics:
# comma-separated entries, each an email address or a bare domain, matched
# against a signed-in user's verified email (dfo-website
# src/lib/events/internalEng.ts). The list names staff and this repository is
# public, so the value can't live in Terraform. Terraform owns the secret
# container and the mount, and the real list is added out-of-band as a new
# version (see README.md, "Internal engineering accounts"). Changing the list
# is a new version plus a new revision; no Terraform change is involved.

resource "google_secret_manager_secret" "website_internal_eng_emails" {
  secret_id = "${local.website_name}-internal-eng-emails"

  replication {
    auto {}
  }
}

# Cloud Run fails to start a revision whose secret env var can't be
# resolved, and the mount tracks `latest`, so the secret must never be
# versionless. This placeholder guarantees that between this stack applying
# and the real list being added. The app reads an entry without `@` in the
# middle as a domain and matches it exactly against the domain of a verified
# email. `none` is a single-label name with no public mail domain, so the
# placeholder marks nobody and every event carries `internal_eng: false`.
# Real versions added out-of-band immediately become `latest` and win. The
# literal is not sensitive, so a plain (state-visible) version is fine here.
resource "google_secret_manager_secret_version" "website_internal_eng_emails_placeholder" {
  secret      = google_secret_manager_secret.website_internal_eng_emails.id
  secret_data = "none"
}

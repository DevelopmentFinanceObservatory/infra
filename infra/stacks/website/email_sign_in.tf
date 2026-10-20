# Settings for email sign-in by emailed code (dfo-website /login). The app
# turns it on only when all of these are set: a mail transport (SES_ROLE_ARN
# with SES_REGION), AUTH_EMAIL_FROM, TURNSTILE_SITE_KEY and
# TURNSTILE_SECRET_KEY. The plain values come from variables that stay null
# until they exist (var.ses_role_arn, var.ses_region, var.turnstile_site_key).
# Cloudflare issues the Turnstile secret key, so Terraform owns the secret
# container and the mount, and the value is added out-of-band as a new
# version (see README.md, "Email sign-in").

resource "google_secret_manager_secret" "website_turnstile_secret_key" {
  secret_id = "${local.website_name}-turnstile-secret-key"

  replication {
    auto {}
  }
}

# Cloud Run fails to start a revision whose secret env var can't be
# resolved, and the mount tracks `latest`, so the secret must always have a
# version. The app trims every value and reads a blank one as unset, so a
# single space keeps email sign-in off whatever else is set, until the real
# key is added as a new version and becomes `latest`. The literal is public,
# so a plain, state-visible version is fine here.
resource "google_secret_manager_secret_version" "website_turnstile_secret_key_placeholder" {
  secret      = google_secret_manager_secret.website_turnstile_secret_key.id
  secret_data = " "
}

locals {
  email_sign_in_env_vars = merge(
    {
      # The SES role's policy allows sending only as this address, compared case-sensitively.
      AUTH_EMAIL_FROM = "DFO Studio <studio@developmentfinance.org>"
    },
    # Both or neither, which var.ses_region's validation enforces.
    var.ses_role_arn == null ? {} : { SES_ROLE_ARN = var.ses_role_arn, SES_REGION = var.ses_region },
    var.turnstile_site_key == null ? {} : { TURNSTILE_SITE_KEY = var.turnstile_site_key },
  )

  # The mount tracks `latest` because the real key is added out-of-band and the newest version must win.
  email_sign_in_secret_env_vars = {
    TURNSTILE_SECRET_KEY = { secret_id = google_secret_manager_secret.website_turnstile_secret_key.secret_id }
  }
}

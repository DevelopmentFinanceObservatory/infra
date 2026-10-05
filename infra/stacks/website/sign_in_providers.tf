# Social sign-in providers for the website. Sign-in is social-only
# (Better Auth), so /login works only while at least one provider is listed
# here. Each provider's OAuth client is registered by hand with the provider
# and its two halves stored out-of-band in
# <website name>-<provider>-client-id and -client-secret, such as
# dfo-dev-website-staging-google-client-id or dfo-prod-website-google-client-id (README,
# "Sign-in providers"). The app offers a provider only when both halves are
# set, so each listed provider mounts as a pair. The mounts track latest, so
# a reissued client reaches the next revision with no infra change.
#
# Data sources, not resources: a listed provider whose secrets don't exist
# fails the plan, so a PR cannot merge into a state where the service can't
# start new revisions.

locals {
  sign_in_providers = ["google", "github", "microsoft"]

  sign_in_secret_env_vars = merge([
    for p in local.sign_in_providers : {
      "${upper(p)}_CLIENT_ID"     = { secret_id = data.google_secret_manager_secret.sign_in["${p}-client-id"].secret_id }
      "${upper(p)}_CLIENT_SECRET" = { secret_id = data.google_secret_manager_secret.sign_in["${p}-client-secret"].secret_id }
    }
  ]...)
}

data "google_secret_manager_secret" "sign_in" {
  for_each  = toset(flatten([for p in local.sign_in_providers : ["${p}-client-id", "${p}-client-secret"]]))
  secret_id = "${local.website_name}-${each.key}"
}

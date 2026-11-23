# The secrets that sign the tag at the end of every API key
# (API_KEY_TAG_SECRETS): a comma-separated list, the first entry signing new
# keys and every entry verifying. The tag lets the website's proxy refuse a
# made-up key before it reads the key store. A production revision refuses to
# start without a valid list, so the first apply generates one here. Kept
# apart from BETTER_AUTH_SECRET, so rotating that one leaves keys alone.
#
# A rotation adds versions by hand, first `old,new` and then `new,old`, and
# moves var.api_key_tag_secrets_version to each in turn, so the old secret
# keeps verifying throughout. Dropping a secret voids every key it signed
# (see README.md, "API key tag secrets"). The generated version below is only
# the first, version 1.

locals {
  # Write-only counter for the generated first version. Rotate by adding
  # versions by hand: a new generated value has no overlap with the old one
  # and voids every API key in use, and prevent_destroy below refuses the
  # replacement a bump would plan.
  website_api_key_tag_secrets_version = 1
}

# Alphanumeric only: the value is a comma-separated list, so a generated comma
# would split it.
ephemeral "random_password" "website_api_key_tag_secret" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "website_api_key_tag_secrets" {
  secret_id = "${local.website_name}-api-key-tag-secrets"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "website_api_key_tag_secrets" {
  secret                 = google_secret_manager_secret.website_api_key_tag_secrets.id
  secret_data_wo         = ephemeral.random_password.website_api_key_tag_secret.result
  secret_data_wo_version = local.website_api_key_tag_secrets_version

  # Destroying or replacing this version deletes the secret that signed every
  # key issued before the first rotation, and voids those keys.
  # scripts/check-destroys.sh guards secrets, not versions, since other
  # stacks rotate by replacing pinned versions.
  lifecycle {
    prevent_destroy = true
  }
}

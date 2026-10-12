# The shared secret that locks the load balancer to Cloudflare. Cloudflare's
# Transform Rule adds it to every request it forwards, and the Cloud Armor
# policy in armor.tf admits only requests that carry it.
#
# The secret is ordinary managed state because two resources need the same
# value, the Cloud Armor rule and the Cloudflare Transform Rule. It sits in
# the private state bucket. Anyone with
# compute.securityPolicies.get on the project can also read it from the
# Cloud Armor rule's expression.

locals {
  # Bump to rotate the secret. See README.md for what a rotation does.
  origin_auth_rotation = 1

  origin_auth_header_value = random_password.origin_auth.result
}

# Alphanumeric only, so the value needs no escaping inside the Cloud Armor
# expression's string literal or the Cloudflare header value.
resource "random_password" "origin_auth" {
  length  = 48
  special = false

  keepers = {
    rotation = local.origin_auth_rotation
  }
}

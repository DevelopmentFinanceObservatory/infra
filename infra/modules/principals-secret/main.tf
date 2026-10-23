terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

# A stack's hand-made principals secret, which holds the addresses the stack
# grants or notifies, so no address sits in the repository or in plan output.
# scripts/bootstrap-principals.sh writes it, checking the same rules as the
# postconditions below:
#   - the secret is the script's output, one JSON object in jq's compact,
#     key-sorted form, which for the characters allowed below matches
#     jsonencode byte for byte, so no key is repeated;
#   - its keys are exactly the stack's schema keys;
#   - each of those is an object keyed by labels matching \A[a-z0-9_-]+\z;
#   - each value matches its form: an IAM member (group:, user: or
#     serviceAccount: before an address, or domain: before a domain) or a bare
#     address, in lower-case ASCII only;
#   - each object holds at least its schema's min entries;
#   - no value appears under two labels of one object.
# Lower case keeps the duplicate check exact, since IAM compares addresses
# without regard to case, and keeps CI's masking of each value exact. Labels
# key the stack's resources, since Terraform rejects sensitive for_each keys
# and an address in a key would print in every plan.
# schemas.json maps each stack to its secret's top-level keys, each with the
# form of its values (member or email) and the fewest entries it holds.
# scripts/bootstrap-principals.sh reads the same file.
locals {
  secret = "projects/${var.project_id}/secrets/${var.namespace}-${var.stack}-principals"
  schema = jsondecode(file("${path.module}/schemas.json"))[var.stack]
  forms = {
    member = "\\A((group|user|serviceAccount):[a-z0-9._%+-]+@|domain:)[a-z0-9.-]+\\z"
    email  = "\\A[a-z0-9._%+-]+@[a-z0-9.-]+\\z"
  }
}

data "google_secret_manager_secret_version" "this" {
  secret = local.secret

  lifecycle {
    postcondition {
      condition     = try(jsonencode(jsondecode(self.secret_data)) == self.secret_data, false)
      error_message = "${local.secret} must hold the compact, key-sorted JSON that scripts/bootstrap-principals.sh writes. A file written any other way can repeat a key, which jsondecode settles silently."
    }
    postcondition {
      condition = try(
        toset(keys(jsondecode(self.secret_data))) == toset(keys(local.schema))
        && alltrue([for key in keys(local.schema) : can(keys(jsondecode(self.secret_data)[key]))]),
        false,
      )
      error_message = "${local.secret} must hold one JSON object with exactly the keys ${join(", ", sort(keys(local.schema)))}, each an object."
    }
    postcondition {
      condition = try(alltrue(flatten([
        for key in keys(local.schema) : [
          for label in keys(jsondecode(self.secret_data)[key]) : can(regex("\\A[a-z0-9_-]+\\z", label))
        ]
      ])), false)
      error_message = "Every label in ${local.secret} must be lower-case letters, digits, hyphens and underscores."
    }
    postcondition {
      condition = try(alltrue(flatten([
        for key, rule in local.schema : [
          for value in values(jsondecode(self.secret_data)[key]) : can(regex(local.forms[rule.form], value))
        ]
      ])), false)
      error_message = "Every value in ${local.secret} must be in lower-case ASCII and match its object's form: ${join(", ", [for key in sort(keys(local.schema)) : "${key} ${local.schema[key].form}"])}."
    }
    postcondition {
      condition = try(alltrue([
        for key, rule in local.schema : length(jsondecode(self.secret_data)[key]) >= rule.min
      ]), false)
      error_message = "${local.secret} has an object below its minimum: ${join(", ", [for key in sort(keys(local.schema)) : "${key} ${local.schema[key].min}"])}."
    }
    postcondition {
      condition = try(alltrue([
        for key in keys(local.schema) :
        length(distinct(values(jsondecode(self.secret_data)[key]))) == length(jsondecode(self.secret_data)[key])
      ]), false)
      error_message = "An object in ${local.secret} holds the same value under two labels, so removing either label would revoke or unsubscribe both."
    }
  }
}

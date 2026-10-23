terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

# A stack's hand-made principals secret. README.md states the rules the
# postconditions below check, and schemas.json holds the label pattern, the
# pattern of each value form, and each stack's schema: its top-level keys,
# each with a form and the fewest entries it holds.
# scripts/bootstrap-principals.sh reads the same file, so both sides apply the
# same patterns. The patterns use only ASCII classes and \A and \z, which RE2
# (regex here) and Oniguruma (jq's test) read the same way.
locals {
  schemas = jsondecode(file("${path.module}/schemas.json"))
  secret  = "projects/${var.project_id}/secrets/${var.namespace}-${var.stack}-principals"
  schema  = local.schemas.stacks[var.stack]
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
          for label in keys(jsondecode(self.secret_data)[key]) : can(regex(local.schemas.label, label))
        ]
      ])), false)
      error_message = "Every label in ${local.secret} must be lower-case letters, digits, hyphens and underscores."
    }
    postcondition {
      condition = try(alltrue(flatten([
        for key, rule in local.schema : [
          for value in values(jsondecode(self.secret_data)[key]) : can(regex(local.schemas.forms[rule.form], value))
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

variable "project_id" {
  description = "Project that holds the secret."
  type        = string
}

variable "namespace" {
  description = "Environment namespace, such as dfo-dev. The secret is <namespace>-<stack>-principals."
  type        = string
}

variable "stack" {
  description = "Name of the calling stack, a key of schemas.json. It names the secret and picks the schema the secret must meet."
  type        = string

  validation {
    condition     = contains(keys(jsondecode(file("${path.module}/schemas.json"))), var.stack)
    error_message = "The stack must be a key of schemas.json in this module."
  }
}

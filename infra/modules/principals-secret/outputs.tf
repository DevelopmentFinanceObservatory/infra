output "principals" {
  description = "The decoded secret: an object of label-keyed objects of members or addresses. Sensitive; take for_each keys with nonsensitive(keys(...))."
  value       = jsondecode(data.google_secret_manager_secret_version.this.secret_data)
  sensitive   = true
}

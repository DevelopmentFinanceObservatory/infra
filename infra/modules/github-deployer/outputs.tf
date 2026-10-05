output "email" {
  description = "Service account email."
  value       = google_service_account.this.email
}

output "member" {
  description = "Service account member string, e.g. \"serviceAccount:<email>\" — usable directly in IAM member/members arguments."
  value       = google_service_account.this.member
}

output "service_account_id" {
  description = "Fully-qualified service account resource id."
  value       = google_service_account.this.id
}

output "name" {
  description = "Service account resource name."
  value       = google_service_account.this.name
}

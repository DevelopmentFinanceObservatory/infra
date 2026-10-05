terraform {
  backend "gcs" {
    bucket = "tf-state-dfo-prod-prod-fin-observatory"
    prefix = "terraform/state/dfo-prod/foundation"
  }
}

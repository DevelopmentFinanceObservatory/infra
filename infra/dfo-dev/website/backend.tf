terraform {
  backend "gcs" {
    bucket = "tf-state-dfo-dev-dev-fin-observatory"
    prefix = "terraform/state/dfo-dev/website"
  }
}

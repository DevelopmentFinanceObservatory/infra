# Data Commons Platform Terraform Setup

This directory contains Terraform configuration for a new Data Commons Platform instance.

Data Commons is an open knowledge graph for integrating and querying structured data across domains. The Data Commons Platform is the deployable infrastructure stack that runs Data Commons services in your GCP project.

## Remote State Management

Terraform state is configured to be stored remotely in Google Cloud Storage:

- **Bucket**: `gs://tf-state-dfo-dev-dev-fin-observatory`
- **Prefix**: `terraform/state/dfo-dev`

This enables team collaboration, state locking, and automated pipeline deployments. The bucket is configured with Uniform Bucket-Level Access and object versioning.

## What This Terraform Creates

This setup deploys core Data Commons Platform infrastructure on GCP using the `infra/dcp` module, including Cloud Run services, Cloud Spanner resources, IAM bindings, and supporting service configuration.

## Configure Variables

Set environment-specific values in `terraform.tfvars` (for example `project_id`, `instance_name`, and `dc_api_key`), and update module arguments in `main.tf` if you want to enable or tune additional features.

## Learn More About Variables

For the full list of supported module inputs and defaults, see:

- https://github.com/datacommonsorg/datacommons/blob/main/infra/dcp/variables.tf
- https://github.com/datacommonsorg/datacommons/blob/main/infra/dcp/outputs.tf
- https://github.com/datacommonsorg/datacommons/blob/main/infra/dcp/terraform.tfvars.template
- https://github.com/datacommonsorg/datacommons/blob/main/infra/dcp/README.md

## Next Steps

1. Review `terraform.tfvars` and update values if needed.
2. Initialize Terraform:
   ```bash
   terraform init
   ```
3. Preview infrastructure changes:
   ```bash
   terraform plan
   ```
4. Deploy infrastructure:
   ```bash
   terraform apply
   ```

Generated using the Data Commons CLI tool: https://github.com/datacommonsorg/datacommons

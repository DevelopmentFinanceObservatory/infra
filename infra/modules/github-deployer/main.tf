resource "google_service_account" "this" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = var.display_name != "" ? var.display_name : var.account_id
  description  = var.description
}

locals {
  # Four WIF scoping modes, in precedence order:
  #   - both wif_environment and wif_ref set: only a job that declares that
  #     GitHub Environment *and* runs on that git ref may impersonate the SA,
  #     matched on attribute.repo_env_ref
  #     (<repository_id>:<wif_environment>:<wif_ref>). This is the right mode
  #     for an image deployer. Scoped to the Environment alone, the set of
  #     refs that may deploy is decided by that Environment's deployment
  #     branch policy, which lives in the service repository and can be
  #     widened there without anything here changing.
  #   - wif_environment set alone: only a job that declares that GitHub Environment
  #     may impersonate the SA, matched on attribute.repo_environment
  #     (<repository_id>:<wif_environment>). Use it for any deployer whose CI
  #     gates on a GitHub Environment rather than a protected branch. A job
  #     that declares no `environment:` carries no such claim, and the
  #     provider maps the bare repository id in its place, which cannot
  #     collide with a <repository_id>:<value> member.
  #   - wif_ref set: only a workflow run on that git ref may impersonate the
  #     SA, matched on attribute.repo_ref (<repository_id>:<wif_ref>).
  #     Combined with branch protection on that ref (no direct pushes,
  #     required PR review), that means only reviewed, merged code can.
  #   - neither set: any GitHub Actions workflow in var.repository may
  #     impersonate the SA (the repo-scoped default).
  # Setting both is a narrowing rather than a conflict, because these are two
  # independent claims and not two shapes of one subject. A job on a given
  # ref that also declares an Environment populates repo_ref and
  # repo_environment alike, so either alone admits it and both together
  # admit less than either.
  #
  # No mode matches the raw `sub` claim, because the subject's shape is
  # GitHub's to change: it is migrating from the legacy `repo:<owner>/<repo>`
  # prefix to the immutable `repo:<owner>@<owner_id>/<repo>@<repo_id>` form
  # one repository at a time, and `use_default: true` on every repository
  # using this pool leaves nothing here to opt into or out of. A
  # subject-matching member survives only until GitHub moves that repository,
  # and it fails closed but quietly: impersonation is denied, no
  # configuration changed, so plans stay clean and the denial waits for the
  # next run that authenticates.
  #
  # The scoped modes compose from repository_id rather than the name for
  # the same reason the pool's attribute condition gates on ids: a rename or
  # transfer preserves the id, so a name-composed member would keep
  # exchanging tokens and match nothing. The repo-scoped default still keys
  # off the name and carries that narrower exposure.
  wif_member = (
    var.wif_environment != null && var.wif_ref != null ? "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/attribute.repo_env_ref/${var.repository_id}:${var.wif_environment}:${var.wif_ref}" :
    var.wif_environment != null ? "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/attribute.repo_environment/${var.repository_id}:${var.wif_environment}" :
    var.wif_ref != null ? "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/attribute.repo_ref/${var.repository_id}:${var.wif_ref}" :
    "principalSet://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/attribute.repository/${var.repository}"
  )
}

# Let this repo's GitHub Actions impersonate the SA via WIF — scoped to the
# one repo by default, or further scoped to one git ref or one GitHub
# Environment when wif_ref or wif_environment is set.
resource "google_service_account_iam_member" "wif" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_member

  lifecycle {
    # member is part of this resource's identifying tuple, so changing
    # wif_ref or wif_environment (and therefore local.wif_member) is a
    # replace, not an update. Without create_before_destroy the old binding
    # is destroyed before the new one exists, leaving the SA briefly
    # unimpersonable by anything — a deploy authenticating in that window
    # gets a hard 403. Two members briefly coexisting on the same role only
    # ever over-permits for a moment, never under-permits, so this is safe.
    create_before_destroy = true

  }
}

resource "google_project_iam_member" "project_roles" {
  for_each = toset(var.project_roles)
  project  = var.project_id
  role     = each.value
  member   = google_service_account.this.member
}

# Repository-scoped alternative to project_roles, for roles that Artifact
# Registry supports granting per-repository (e.g. artifactregistry.writer) so
# an image-deployer SA doesn't get write access to every repo in the project.
resource "google_artifact_registry_repository_iam_member" "repository_roles" {
  for_each = {
    for entry in var.artifact_registry_repositories :
    # repository_id is only unique within a location, so both belong in the
    # key — otherwise two repos with the same id in different locations
    # granted to the same SA would collide.
    "${entry.location}:${entry.repository_id}:${entry.role}" => entry
  }

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository_id
  role       = each.value.role
  member     = google_service_account.this.member
}

resource "google_storage_bucket_iam_member" "state_bucket" {
  count  = var.state_bucket != null ? 1 : 0
  bucket = var.state_bucket
  role   = var.state_bucket_role
  member = google_service_account.this.member

  dynamic "condition" {
    for_each = var.state_bucket_object_prefixes != null ? [1] : []
    content {
      title = "state-bucket-object-prefixes"
      # GCS rejects a condition carrying more than 12 logical operators, so
      # the object arm tests resource.type once and ORs the prefixes inside
      # it rather than repeating the type test per prefix. That costs two
      # operators plus one per prefix instead of two per prefix, leaving
      # room to roughly double the stack list before hitting the ceiling.
      expression = join(" || ", [
        "(resource.type == \"storage.googleapis.com/Bucket\" && resource.name == \"projects/_/buckets/${var.state_bucket}\")",
        "(resource.type == \"storage.googleapis.com/Object\" && (${join(" || ", [
          for prefix in var.state_bucket_object_prefixes :
          "resource.name.startsWith(\"projects/_/buckets/${var.state_bucket}/objects/${prefix}\")"
        ])}))",
      ])
    }
  }

  lifecycle {
    # condition is part of this resource's identifying tuple (like member on
    # the WIF binding above), so adding, removing, or narrowing
    # state_bucket_object_prefixes is a replace. Without
    # create_before_destroy the grantee loses all bucket access for the
    # window between destroy and create; with it, the old and new bindings
    # briefly coexist on the same role, which only ever over-permits and
    # never under-permits.
    create_before_destroy = true
  }
}

# principals-secret

Reads a stack's hand-made Secret Manager secret `<namespace>-<stack>-principals`, which holds the addresses the stack grants or notifies, and checks it at plan. No address sits in this repository or in a plan log: the module's output is sensitive, and every value prints in plan output as `(sensitive value)`. The `foundation`, `ai` and `telemetry` stacks call it with their stack name. Plan fails while the secret, or the planner's access to it, does not exist.

`schemas.json` holds each stack's schema (its top-level keys, each with a value form and the fewest entries it holds), the label pattern, the pattern of each form, the member prefix pattern, and the minimum value length. `scripts/bootstrap-principals.sh` reads the same file, so the script and the module apply the same patterns. The patterns use only ASCII classes and the `\A` and `\z` anchors, which RE2 (Terraform's `regex`) and Oniguruma (jq's `test`) read the same way.

## Rules

- The secret is one JSON object whose keys are exactly the stack's schema keys, each holding an object.
- The secret holds the compact, key-sorted JSON the script writes. For the characters the rules allow, that matches `jsonencode` byte for byte, so a version written any other way fails plan. The rule catches a repeated key, which `jsondecode` settles silently.
- Each inner object maps labels to values. A label holds only lower-case letters, digits, hyphens and underscores. Labels key the stack's resources, since Terraform rejects sensitive `for_each` keys, so they appear in resource addresses and plan output, and an address cannot be one.
- A value is a string. A `member` value is one of the fixed prefixes `group:`, `user:` or `serviceAccount:` (which keeps its capital) followed by an address, or `domain:` followed by a domain. An `email` value is a bare address with no prefix. The address or domain is lower-case ASCII. Lower case makes the duplicate check exact, since IAM compares addresses without regard to case, and keeps CI's masking of each value exact.
- Each value, and its address with the member prefix removed, is at least `min_length` characters (4), the shortest `scripts/mask-principals.sh` can mask. The mask step reads every principals secret in the project, so a shorter value would block every CI plan there.
- Each object holds at least its schema's minimum. Telemetry's `alerts` needs one entry, and every other object may be empty.
- No value appears under two labels of one object, since removing either label would revoke both.

## Writing the secret

Write the JSON to a file outside the repository and run

```sh
scripts/bootstrap-principals.sh <project> <namespace>-<stack>-principals principals.json
```

The script refuses a file that breaks a rule before any `gcloud` call. It then creates the secret if it is absent, adds the file's compact, key-sorted form as the latest version, and grants `dfo-infra-planner` `roles/secretmanager.secretAccessor` on it. The foundation stack makes the same grant for each stack in `principals_secret_stacks`, but a stack's first plan can run before that apply. The next apply of the stack moves its grants to the new members.

## Relabelling

A relabel with the same value needs a `moved` block for each resource the label keys, for example `moved { from = google_service_account_iam_member.applier_impersonator["old"] to = google_service_account_iam_member.applier_impersonator["new"] }`. Without one, the plan destroys one instance and creates the other on the same binding in no fixed order, and a delete that runs last revokes the member. Labels are not addresses, so the block is safe to commit. The resources each label keys:

- foundation: `applier_impersonator` for an impersonator; the five `ingestion_*` resources for an ingestion operator, where `ingestion_viewer` holds one instance per role, keyed `"<label> <role>"`; `budget_email` for a budget alert recipient.
- ai: `studio_api_token_reader` or `mcp_api_token_readers`.
- telemetry: `reporting_readers`, `reporting_readers_job_user` and `reporting_readers_mcp_tool_user` for a reader; `alert_email` for an alert recipient.

The stack reads the secret's latest version at every plan, so the new version and the `moved` blocks must land with no apply of that stack between them. Open the PR with the `moved` blocks, write the new version with the script, re-run the PR's plan, which should show only moves, and merge, so that the PR's own apply is the next apply of the stack. An apply that runs after the new version but before the merge sees the new labels without the `moved` blocks and replaces each grant in no fixed order, which can revoke the member; if one does, the next apply re-creates the grant. Merging the `moved` blocks before the new version exists moves state to labels the secret lacks and races the same way. The duplicate rule rules out a gentler path of adding the new label before removing the old one.

## Member-keyed state

The grants were once keyed by member string. `removed` blocks for `applier_impersonators` and the five `ingestion_operator_*` resources in `infra/stacks/foundation/main.tf`, and for `studio_api_token_readers` in `infra/stacks/ai/studio_token.tf`, make Terraform forget those state entries without destroying the live bindings. The label-keyed resources create the same bindings again, which IAM accepts as no change.

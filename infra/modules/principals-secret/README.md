# principals-secret

Reads a stack's hand-made Secret Manager secret `<namespace>-<stack>-principals`, which holds the addresses the stack grants or notifies, and checks it at plan. No address sits in this repository or in a plan log: the module's output is sensitive, and every value prints in plan output as `(sensitive value)`. The `foundation`, `apis`, `ai` and `telemetry` stacks call it with their stack name. Plan fails while the secret, or the planner's access to it, does not exist.

`schemas.json` holds each stack's schema (its top-level keys, each with a value form and the fewest entries it holds), the label pattern, the pattern of each form with a sentence saying what it accepts, the type prefix pattern, and the minimum value length. `scripts/bootstrap-principals.sh` reads the same file, so the script and the module apply the same patterns. The patterns use only ASCII classes and the `\A` and `\z` anchors, which RE2 (Terraform's `regex`) and Oniguruma (jq's `test`) read the same way.

## Rules

- The secret is one JSON object whose keys are exactly the stack's schema keys, each holding an object.
- The secret holds the compact, key-sorted JSON the script writes. For the characters the rules allow, that matches `jsonencode` byte for byte, so a version written any other way fails plan. The rule catches a repeated key, which `jsondecode` settles silently.
- Each inner object maps labels to values. A label holds only lower-case letters, digits, hyphens and underscores. Labels key the stack's resources, since Terraform rejects sensitive `for_each` keys, so they appear in resource addresses, plan output and public plan comments, and an address cannot be one. Name a label by role, such as `dev-1` or `devs`.
- A value is a string. A `person` value is `group:` or `user:` followed by an address. Every object that grants IAM takes `person` values: `applier_impersonators`, `ingestion_operators`, `mcp_token_readers`, `studio_token_readers`, `readers` and `invokers`. A service account, a workload identity principal (`principal://` or `principalSet://`) or a domain gets a named Terraform resource in the stack that owns it, such as `infra/stacks/apis/eval_reader.tf`. The schema rules out machine members only, so the entries are people. A person who also holds the same role through a hand-made binding loses it when the entry is removed, so grant people through the secret only. An `email` value is a bare address with no prefix. The address is lower-case ASCII. Lower case makes the duplicate check exact, since IAM compares addresses without regard to case, and keeps CI's masking of each value exact.
- Each value, and its address with the type prefix removed, is at least `min_length` characters (4), the shortest `scripts/mask-principals.sh` can mask. The mask step reads every principals secret in the project, so a shorter value would block every CI plan there.
- Each object holds at least its schema's minimum. Telemetry's `alerts` needs one entry, and every other object may be empty.
- No value appears under two labels of one object, since removing either label would revoke both.

## Writing the secret

Each run of the script adds a version that replaces the whole secret. A file that omits an existing entry drops it, and the next apply of the stack revokes its grant. The file therefore starts from the latest version and lives outside the repository.

To change an existing secret, read the latest version into a temporary file:

```sh
f=$(mktemp)
gcloud secrets versions access latest --secret <namespace>-<stack>-principals --project <project> > "$f"
```

Add, change or remove entries in `"$f"`, then write it and remove the file once the script succeeds:

```sh
scripts/bootstrap-principals.sh <project> <namespace>-<stack>-principals "$f" && rm "$f"
```

To create a secret, write a file that holds every key of the stack's schema, each an object (empty where the stack has no entries), and run the same script command.

The script refuses a file that breaks a rule before any `gcloud` call. It then creates the secret if it is absent, adds the file's compact, key-sorted form as the latest version, and grants `dfo-infra-planner` `roles/secretmanager.secretAccessor` on it. The foundation stack makes the same grant for each stack in `principals_secret_stacks`, but a stack's first plan can run before that apply.

Writing the secret starts no apply. Dispatch the `Terraform Apply` workflow with `stack` set to the stack's name, on the branch of the environment: `dev` for dfo-dev and `main` for dfo-prod.

```sh
gh workflow run apply.yml --ref <dev or main> -f stack=<stack>
```

The apply moves the stack's grants to the new members. A relabel is the exception: an apply that runs between the new version and the merge of the `moved` blocks can revoke members, so follow the order in [Relabelling](#relabelling) and dispatch no apply before the merge.

## Relabelling

A relabel with the same value needs a `moved` block for each resource the label keys, for example `moved { from = google_service_account_iam_member.applier_impersonator["old"] to = google_service_account_iam_member.applier_impersonator["new"] }`. Without one, the plan destroys one instance and creates the other on the same binding in no fixed order, and a delete that runs last revokes the member. Labels are not addresses, so the block is safe to commit. The resources each label keys:

- foundation: `applier_impersonator` for an impersonator; the five `ingestion_*` resources for an ingestion operator, where `ingestion_viewer` holds one instance per role, keyed `"<label> <role>"`; `budget_email` for a budget alert recipient.
- apis: `apis_invoker` and `apis_viewer` for an invoker.
- ai: `studio_api_token_reader` or `mcp_api_token_readers`.
- telemetry: `reporting_readers`, `reporting_readers_job_user` and `reporting_readers_mcp_tool_user` for a reader; `alert_email` for an alert recipient.

The stack reads the secret's latest version at every plan, so the new version and the `moved` blocks must land with no apply of that stack between them. Open the PR with the `moved` blocks, write the new version with the script, re-run the PR's plan, which should show only moves, and merge, so that the PR's own apply is the next apply of the stack. An apply that runs after the new version but before the merge sees the new labels without the `moved` blocks and replaces each grant in no fixed order, which can revoke the member; if one does, the next apply re-creates the grant. Merging the `moved` blocks before the new version exists moves state to labels the secret lacks and races the same way. The duplicate rule rules out a gentler path of adding the new label before removing the old one.

## Member-keyed state

The grants were once keyed by member string. `removed` blocks for `applier_impersonators` and the five `ingestion_operator_*` resources in `infra/stacks/foundation/main.tf`, and for `studio_api_token_readers` in `infra/stacks/ai/studio_token.tf`, make Terraform forget those state entries without destroying the live bindings. The label-keyed resources create the same bindings again, which IAM accepts as no change.

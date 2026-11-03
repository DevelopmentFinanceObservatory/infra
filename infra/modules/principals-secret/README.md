# principals-secret

Reads a stack's hand-made Secret Manager secret `<namespace>-<stack>-principals`, which holds the addresses the stack grants or notifies, and checks it at plan. No address sits in this repository or in a plan log: the module's output is sensitive, and every value prints in plan output as `(sensitive value)`. The `foundation`, `apis`, `ai` and `telemetry` stacks call it with their stack name. Plan fails while the secret, or the planner's access to it, does not exist.

`schemas.json` holds each stack's schema (its top-level keys, each with a value form and the fewest entries it holds), the label pattern, the pattern of each form with a sentence saying what it accepts, the member type prefix pattern, and the minimum value length. `scripts/bootstrap-principals.sh` and `scripts/mask-principals.sh` read the same file, so the module and both scripts apply the same patterns. The patterns use only ASCII classes and the `\A` and `\z` anchors, which RE2 (Terraform's `regex`) and Oniguruma (jq's `test`) read the same way.

## Rules

- The secret is one JSON object whose keys are exactly the stack's schema keys, each holding an object.
- The secret holds the compact, key-sorted JSON the script writes. For the characters the rules allow, that matches `jsonencode` byte for byte, so a version written any other way fails plan. The rule catches a repeated key, which `jsondecode` settles silently.
- Each inner object maps labels to values. A label holds only lower-case letters, digits, hyphens and underscores. Labels key the stack's resources, since Terraform rejects sensitive `for_each` keys, so they appear in resource addresses, plan output and public plan comments, and an address cannot be one. Name a label by role, such as `dev-1` or `devs`.
- A value is a string. A `person` value is `group:` or `user:` followed by an address, so it names a person or a group of people. Every object that grants IAM takes `person` values: `applier_impersonators`, `ingestion_operators`, `mcp_token_readers`, `studio_token_readers`, `readers` and `invokers`. A service account, a workload identity principal (`principal://` or `principalSet://`) or a domain gets a named Terraform resource in the stack that owns it, such as `infra/stacks/apis/eval_reader.tf`. A person who also holds the same role through a hand-made binding loses it when the entry is removed, so grant people through the secret only. An `email` value is a bare address with no prefix. The address is lower-case ASCII. Lower case makes the duplicate check exact, since IAM compares addresses without regard to case, and keeps CI's masking of each value exact.
- Each value, and its address with the type prefix removed, is at least `min_length` characters (4), the shortest `scripts/mask-principals.sh` can mask. The mask step reads every principals secret in the project, so a shorter value would block every CI plan there.
- Each object holds at least its schema's minimum. Telemetry's `alerts` needs one entry, and every other object may be empty.
- No value appears under two labels of one object, since removing either label would revoke both.

## Writing the secret

Each write adds a version that replaces the whole secret, and the next apply of the stack revokes the grant of any entry the new version omits. `scripts/bootstrap-principals.sh` therefore starts every change from the latest version. The script's copy lives in a private temporary directory that it removes on exit. An editor's own swap, backup or undo files follow that editor's configuration.

Create a secret from a file that holds every key of the stack's schema, each an object (empty where the stack has no entries). Keep the file outside the repository and remove it afterwards:

```sh
scripts/bootstrap-principals.sh <project> <namespace>-<stack>-principals <file>
```

The script validates the file, creates the secret if it is missing, adds the file's compact, key-sorted form as the first version when the secret has no enabled version, and then grants `dfo-infra-planner` `roles/secretmanager.secretAccessor` on it. Each step is skipped or repeated harmlessly, so the same command completes a run that failed part way. A secret that already has a version is left as it is when the file's canonical form equals the latest version's bytes. When the content differs, the script refuses and points at `edit`. The grant comes last because `dfo-infra-planner` does not exist until the foundation stack first applies. In a fresh environment the script then writes the secret and its first version, shows gcloud's error and names the missing account, and exits 1 with the command to run after foundation's first apply, `grant`. The foundation stack makes the same grant for each stack in `principals_secret_stacks`, but a stack's first plan can run before that apply.

Grant the planner on its own with `grant`:

```sh
scripts/bootstrap-principals.sh grant <project> <namespace>-<stack>-principals
```

`grant` adds the `dfo-infra-planner` `roles/secretmanager.secretAccessor` binding that create ends with. It is idempotent, so it is safe to run again, and it writes no version. If it fails, it exits 1 with gcloud's error and the same command to run once the cause is fixed. That is foundation's first apply when the planner account is missing, otherwise the operator holding `secretmanager.secrets.getIamPolicy` and `secretmanager.secrets.setIamPolicy` on the secret, as `roles/secretmanager.admin` does.

Change an existing secret with `edit`:

```sh
scripts/bootstrap-principals.sh edit <project> <namespace>-<stack>-principals
```

The script reads the latest enabled version, opens `${VISUAL:-${EDITOR:-vi}}` on a copy in a private temporary directory, validates the result against the rules above, and adds it as the next version. It runs the editor through `sh` the way git does, so a command with a quoted path or arguments works. The editor must wait until the file is closed: set `EDITOR` to a command such as `code --wait` for a graphical editor, since one that returns at once leaves the copy unchanged and the script reports "no change". The script removes the directory, with anything the editor left in it, on every exit. A stored version opens pretty-printed, except one that repeats a key, which opens as its raw bytes, since pretty-printing would drop the repeat before validation could see it. A copy whose canonical form equals the stored version's bytes writes nothing. An unchanged save of a version whose bytes are not canonical writes its canonical form, unless the stored version repeats a key. The repeat fails validation, so the editor opens again until the copy drops it. Any non-zero editor exit stops with nothing written, as git does with a commit message. macOS `/usr/bin/vi` can exit 1 after `:wq` when a command error happened in the session. Run `edit` again, or set `EDITOR` to another editor. A copy that breaks a rule is refused and the editor opens again on the same copy. Leaving a refused copy unchanged stops with nothing written. `edit` needs only the rights to list, read and add versions, and makes no IAM change.

Just before it adds the version, the script reads the latest enabled version again and refuses to write when another operator's version has landed since it read. Secret Manager's AddSecretVersion takes no etag, so the check and the write are two calls, and a concurrent writer can only interleave within that gap.

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

// Upsert the Terraform apply comment for one stack on the pull request
// associated with the pushed commit, and write the full init, validate, plan
// and apply output to the job summary. Called from the "Comment apply result
// on PR" step of .github/workflows/apply-stack.yml through
// actions/github-script, which passes github, context and core. The step's
// env carries STACK, each step's outcome and output, and PRINCIPALS_FILE, the
// principal addresses that redact-principals.js strips from the output before
// anything is posted.
const redactor = require("./redact-principals.js");

module.exports = async ({ github, context, core }) => {
  const stack = process.env.STACK;
  const marker = `<!-- tf-apply:${stack} -->`;

  const icon = (outcome) => {
    if (outcome === "success") return "pass";
    if (outcome === "skipped") return "skipped";
    return "fail";
  };

  // Longest run of backticks in `s`, plus one — so a fence built
  // from this can never be closed early by a shorter run already
  // inside the content.
  const fenceFor = (s) => "`".repeat(Math.max(3, ((s.match(/`+/g) || []).reduce((m, r) => Math.max(m, r.length), 0)) + 1));

  // Guard every steps.<id>.outputs.* access for undefined: a step
  // is skipped (and its outputs unset) when an earlier one fails.
  const initOutcome = process.env.INIT_OUTCOME || "skipped";
  const validateOutcome = process.env.VALIDATE_OUTCOME || "skipped";
  const planOutcome = process.env.PLAN_OUTCOME || "skipped";
  const guardOutcome = process.env.GUARD_OUTCOME || "skipped";
  const applyOutcome = process.env.APPLY_OUTCOME || "skipped";
  // Redacted here, at the read, so neither the summary nor the comment can
  // see an address.
  const redact = redactor(process.env.PRINCIPALS_FILE);
  const initStdout = redact(process.env.INIT_STDOUT || "");
  const initStderr = redact(process.env.INIT_STDERR || "");
  const validateStdout = redact(process.env.VALIDATE_STDOUT || "");
  const validateStderr = redact(process.env.VALIDATE_STDERR || "");
  const planStdout = redact(process.env.PLAN_STDOUT || "");
  const planStderr = redact(process.env.PLAN_STDERR || "");
  const applyStdout = redact(process.env.APPLY_STDOUT || "");
  const applyStderr = redact(process.env.APPLY_STDERR || "");

  const initText = [initStdout, initStderr].filter(Boolean).join("\n").trim();
  const validateText = [validateStdout, validateStderr].filter(Boolean).join("\n").trim();
  const planText = [planStdout, planStderr].filter(Boolean).join("\n").trim();
  const applyText = [applyStdout, applyStderr].filter(Boolean).join("\n").trim();

  // The full, untruncated init/validate/apply output always goes to
  // the step summary, so it's never lost even when the comment
  // below gets truncated (or skipped entirely — see below).
  let summaryMd = `## Terraform apply: ${stack}\n\n`;
  summaryMd += `- init: ${icon(initOutcome)}\n`;
  summaryMd += `- validate: ${icon(validateOutcome)}\n`;
  summaryMd += `- apply: ${icon(applyOutcome)}\n\n`;
  if (initStdout || initStderr) {
    const f = fenceFor(initText);
    summaryMd += `### init output\n\n${f}terraform\n${initText}\n${f}\n\n`;
  }
  if (validateStdout || validateStderr) {
    const f = fenceFor(validateText);
    summaryMd += `### validate output\n\n${f}terraform\n${validateText}\n${f}\n\n`;
  }
  if (planStdout || planStderr) {
    const f = fenceFor(planText);
    summaryMd += `### plan output\n\n${f}terraform\n${planText}\n${f}\n\n`;
  }
  if (applyStdout || applyStderr) {
    const f = fenceFor(applyText);
    summaryMd += `### apply output\n\n${f}terraform\n${applyText}\n${f}\n\n`;
  }
  await core.summary.addRaw(summaryMd).write();

  // Headline verdict line: always visible, never inside the
  // collapsed apply section below.
  let verdict;
  if (applyOutcome === "success") {
    if (/^No changes\./m.test(applyText)) {
      verdict = "**No changes.** Infrastructure matches configuration.";
    } else {
      const summaryLine = applyText.match(/^Apply complete! Resources: .*$/m);
      verdict = summaryLine ? `**${summaryLine[0].trim()}**` : "**Apply succeeded.**";
    }
  } else if (initOutcome !== "success" && initOutcome !== "skipped") {
    verdict = "**Init failed.** See details below.";
  } else if (validateOutcome !== "success" && validateOutcome !== "skipped") {
    verdict = "**Validation failed.** See details below.";
  } else if (planOutcome !== "success" && planOutcome !== "skipped") {
    verdict = "**Plan failed.** See details below.";
  } else if (guardOutcome !== "success" && guardOutcome !== "skipped") {
    verdict = "**Blocked by the destroy guard.** The plan would destroy or replace protected resources without the `allow-destroy` label; apply was skipped.";
  } else {
    verdict = "**Apply failed.** See details below.";
  }

  const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  // A push event has no pull_request payload, so context.sha is the
  // merge commit that landed on main.
  const shortSha = context.sha.slice(0, 7);
  const title = `## Terraform Apply — \`${stack}\``;
  const statusTable =
    `| Init | Validate | Apply |\n` +
    `|:---:|:---:|:---:|\n` +
    `| ${icon(initOutcome)} | ${icon(validateOutcome)} | ${icon(applyOutcome)} |`;
  const footer = `<sub>Stack \`${stack}\` · \`${shortSha}\` · @${context.actor} · [run](${runUrl})</sub>`;

  // Prefer apply's own output; fall back to validate's, then
  // init's, when a later step never ran.
  const detailText = applyText || planText || validateText || initText;
  const sectionKind = !detailText ? "none" : applyOutcome === "success" ? "collapsed" : "expanded";

  // Compute the fence once, from the full (pre-truncation) detail
  // text, and reuse it everywhere: truncation only removes
  // content, so it can never lengthen a backtick run and
  // invalidate this fence.
  const fence = fenceFor(detailText || "");

  function buildSection(content, truncationNotice) {
    if (sectionKind === "none") {
      return `_No apply output — see the [job summary](${runUrl})._`;
    }
    const fenced = `${fence}terraform\n${content}\n${fence}`;
    const notice = truncationNotice ? `\n\n${truncationNotice}` : "";
    if (sectionKind === "collapsed") {
      return `<details>\n<summary>Show apply output</summary>\n\n${fenced}${notice}\n\n</details>`;
    }
    // Expanded, not collapsed, so a failure is impossible to miss.
    return `**Output:**\n\n${fenced}${notice}`;
  }

  function buildBody(content, truncationNotice) {
    return [marker, title, verdict, statusTable, buildSection(content, truncationNotice), footer].join("\n\n");
  }

  let body = buildBody(detailText, null);

  // GitHub caps comment bodies at 65,536 chars; truncate the tail
  // of the apply/validate/init text (before wrapping it) once
  // we'd exceed ~65,000.
  const LIMIT = 65000;
  if (body.length > LIMIT) {
    const notice = `_… truncated — full apply output in the [job summary](${runUrl})._`;
    const overhead = buildBody("", notice).length;
    const budget = Math.max(LIMIT - overhead, 0);
    body = buildBody(detailText.slice(0, budget), notice);
  }

  // A push event has no issue/PR number — look up the PR(s)
  // associated with the merge commit instead.
  const prs = await github.rest.repos.listPullRequestsAssociatedWithCommit({
    owner: context.repo.owner,
    repo: context.repo.repo,
    commit_sha: context.sha,
  });
  const prNumber = prs.data[0]?.number;

  if (!prNumber) {
    // No PR to comment on (e.g. a direct push to main) — the full
    // output is already in the job summary, so just skip.
    core.info("No PR associated with this commit; skipping comment.");
    return;
  }

  const comments = await github.paginate(github.rest.issues.listComments, {
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: prNumber,
    per_page: 100,
  });
  const existing = comments.find(
    (c) => c.user && c.user.login === "github-actions[bot]" && c.body && c.body.includes(marker)
  );

  if (existing) {
    await github.rest.issues.updateComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      comment_id: existing.id,
      body,
    });
  } else {
    await github.rest.issues.createComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: prNumber,
      body,
    });
  }
};

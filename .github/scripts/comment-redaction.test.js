// Drives plan-comment.js and apply-comment.js with stub github, core and
// context objects and a principals file in mask-principals.sh's format, and
// checks that neither the posted comment nor the job summary holds a listed
// value in any of its forms. Not wired into CI or pre-commit. Run by hand
// after touching either comment script:
//   node --test .github/scripts/comment-redaction.test.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

// The forms mask-principals.sh lists for `group:Data.Team@Example.org`.
const forms = [
  "Data.Team%40Example.org",
  "Data.Team@Example.org",
  "data.team%40example.org",
  "data.team@example.org",
  "group%3AData.Team%40Example.org",
  "group%3Adata.team%40example.org",
  "group%3adata.team%40example.org",
  "group:Data.Team@Example.org",
  "group:data.team@example.org",
];

// Terraform output as the provider prints it: the id lower-cased, the
// member as configured, and an error quoting it URL-encoded.
const output = [
  "google_project_iam_member.x: Refreshing state... [id=example-project/roles/viewer/group:data.team@example.org]",
  '      + member  = "group:Data.Team@Example.org"',
  "Error: Request failed for members/group%3Adata.team%40example.org",
  "Plan: 1 to add, 0 to change, 0 to destroy.",
].join("\n");

const run = async (script, prefixes) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "comment-"));
  const file = path.join(dir, "principal-addresses");
  fs.writeFileSync(file, forms.map((f) => `${f}\n`).join(""));
  const env = { STACK: "apis", PRINCIPALS_FILE: file };
  for (const p of prefixes) {
    env[`${p}_OUTCOME`] = "success";
    env[`${p}_STDOUT`] = output;
    env[`${p}_STDERR`] = output;
  }
  const saved = { ...process.env };
  Object.assign(process.env, env);
  const posted = [];
  let summary = "";
  const core = {
    summary: {
      addRaw(s) {
        summary += s;
        return this;
      },
      async write() {},
    },
    info() {},
  };
  const github = {
    paginate: async () => [],
    rest: {
      repos: { listPullRequestsAssociatedWithCommit: async () => ({ data: [{ number: 7 }] }) },
      issues: {
        listComments: async () => ({ data: [] }),
        createComment: async ({ body }) => posted.push(body),
        updateComment: async ({ body }) => posted.push(body),
      },
    },
  };
  const context = {
    repo: { owner: "o", repo: "r" },
    issue: { number: 7 },
    payload: {},
    sha: "0123456789abcdef",
    serverUrl: "https://github.example",
    runId: 1,
    actor: "someone",
  };
  try {
    await require(`./${script}`)({ github, context, core });
  } finally {
    for (const k of Object.keys(env)) delete process.env[k];
    Object.assign(process.env, saved);
  }
  return { posted, summary };
};

for (const [script, prefixes] of [
  ["plan-comment.js", ["INIT", "VALIDATE", "PLAN"]],
  ["apply-comment.js", ["INIT", "VALIDATE", "PLAN", "APPLY"]],
]) {
  test(`${script} posts no listed value in any form`, async () => {
    const { posted, summary } = await run(script, prefixes);
    assert.equal(posted.length, 1);
    for (const [where, text] of [
      ["comment", posted[0]],
      ["summary", summary],
    ]) {
      assert.match(text, /Plan: 1 to add/, `${where} lost the plan`);
      for (const f of forms) {
        assert.ok(!text.toLowerCase().includes(f.toLowerCase()), `${where} holds ${f}`);
      }
    }
  });
}

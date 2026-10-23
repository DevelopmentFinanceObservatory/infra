// Strip principal addresses from Terraform output before a workflow posts it
// to a PR comment or the job summary. The runner masks them in logs only, so
// output read from step outputs and posted through the API still holds them.
// scripts/mask-principals.sh writes the list, one value per line, to the
// file the step's PRINCIPALS_FILE names. Called by plan-comment.js and the
// "Comment apply result on PR" step of .github/workflows/apply-stack.yml.
const fs = require("fs");

// Returns redact(text), which replaces every listed value in text with `***`,
// the runner's own mask. Longest first, so a value that contains a shorter one
// (`group:devs@example.org` holds `devs@example.org`) is replaced whole.
// Without the file, redact refuses any non-empty text: masking failed or never
// ran, and nothing says the output is free of addresses.
module.exports = (path) => {
  let values = null;
  if (path) {
    try {
      values = fs.readFileSync(path, "utf8").split("\n").filter(Boolean);
    } catch (err) {
      if (err.code !== "ENOENT") throw err;
    }
  }
  if (values) values.sort((a, b) => b.length - a.length);
  return (text) => {
    if (!text) return text;
    if (values === null) {
      throw new Error(
        `No principal address list at PRINCIPALS_FILE (${path || "unset"}); refusing to post Terraform output that may hold one.`,
      );
    }
    return values.reduce((t, v) => t.split(v).join("***"), text);
  };
};

// Strip principal addresses from Terraform output before a workflow posts it
// to a PR comment or the job summary. The runner masks them in logs only, so
// output read from step outputs and posted through the API still holds them.
// scripts/mask-principals.sh writes the list, one value per line in each of
// its forms (as written, lower-cased, URL-encoded), to the file the step's
// PRINCIPALS_FILE names. Called by plan-comment.js and apply-comment.js.
const fs = require("fs");

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Returns redact(text), which replaces every listed value in text with `***`,
// the runner's own mask, in any letter case, since the provider and IAM
// lower-case emails. Longest first, so a value that contains a shorter one
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
  const pattern = values?.length
    ? new RegExp(values.sort((a, b) => b.length - a.length).map(escape).join("|"), "gi")
    : null;
  return (text) => {
    if (!text) return text;
    if (values === null) {
      throw new Error(`No principal address list at PRINCIPALS_FILE (${path || "unset"}); refusing to post Terraform output that may hold one.`);
    }
    return pattern ? text.replace(pattern, "***") : text;
  };
};

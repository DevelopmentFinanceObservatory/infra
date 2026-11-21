// The stdout and stderr that scripts/tf-capture.sh kept for one Terraform step,
// read from $TF_OUTPUT_DIR, else $RUNNER_TEMP/tf-output. A step that did not run
// left no file and reads as empty.
const fs = require("node:fs");
const path = require("node:path");

module.exports = (name) => {
  const dir = process.env.TF_OUTPUT_DIR || path.join(process.env.RUNNER_TEMP || "", "tf-output");
  const read = (stream) => {
    try {
      return fs.readFileSync(path.join(dir, `${name}.${stream}`), "utf8");
    } catch (err) {
      if (err.code === "ENOENT") return "";
      throw err;
    }
  };
  return { stdout: read("stdout"), stderr: read("stderr") };
};

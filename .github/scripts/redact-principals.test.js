// Tests for redact-principals.js. Not wired into CI or pre-commit. Run by
// hand after touching it:
//   node --test .github/scripts/redact-principals.test.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const redactor = require("./redact-principals.js");

const listFile = (lines) => {
  const file = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), "redact-")),
    "addresses",
  );
  fs.writeFileSync(file, lines.map((l) => `${l}\n`).join(""));
  return file;
};

test("replaces every occurrence, the longer value whole", () => {
  // The file is sorted, as mask-principals.sh writes it, so the shorter
  // address comes first.
  const redact = redactor(
    listFile(["devs@example.org", "group:devs@example.org"]),
  );
  const text =
    "Refreshing state... [id=projects/p/roles/run.invoker/group:devs@example.org]\nmember = devs@example.org";
  assert.equal(
    redact(text),
    "Refreshing state... [id=projects/p/roles/run.invoker/***]\nmember = ***",
  );
});

test("leaves no character of an address that holds a shorter one", () => {
  const redact = redactor(listFile(["a@example.org", "aa@example.org"]));
  assert.equal(redact("aa@example.org a@example.org"), "*** ***");
});

test("matches any letter case and leaves other text alone", () => {
  const redact = redactor(listFile(["Lead.Person@Example.org", "group%3ALead.Person%40Example.org"]));
  assert.equal(
    redact("[id=p/roles/viewer/user:lead.person@example.org] LEAD.PERSON@EXAMPLE.ORG group%3alead.person%40example.org LeadXPerson@Example.org"),
    "[id=p/roles/viewer/user:***] *** *** LeadXPerson@Example.org",
  );
});

test("an empty list passes text through", () => {
  assert.equal(redactor(listFile([]))("Plan: 1 to add"), "Plan: 1 to add");
});

test("a missing list refuses text and passes empty text", () => {
  for (const file of [
    undefined,
    "",
    path.join(os.tmpdir(), "redact-missing", "addresses"),
  ]) {
    const redact = redactor(file);
    assert.equal(redact(""), "");
    assert.throws(() => redact("Plan: 1 to add"), /No principal address list/);
  }
});

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

test("both extensions ship the same shared scripts", () => {
  const root = path.join(__dirname, "..");
  for (const name of ["rules.js", "video-button.js"]) {
    const source = fs.readFileSync(path.join(root, "shared", name), "utf8");
    for (const copy of [`chrome/${name}`, `safari/Resources/${name}`]) {
      assert.equal(fs.readFileSync(path.join(root, copy), "utf8"), source, `${copy} is out of date: run npm run sync`);
    }
  }
});

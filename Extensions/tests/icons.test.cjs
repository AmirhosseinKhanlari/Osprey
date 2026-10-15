const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const extensions = { chrome: path.join(root, "chrome"), safari: path.join(root, "safari", "Resources") };

/** Width and height from a PNG's IHDR chunk. */
function pngSize(file) {
  const data = fs.readFileSync(file);
  assert.equal(data.subarray(1, 4).toString("latin1"), "PNG", `${file} is a PNG`);
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
}

for (const [name, folder] of Object.entries(extensions)) {
  test(`${name}: every icon the manifest names exists at its size`, () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(folder, "manifest.json"), "utf8"));
    const sets = [manifest.icons, manifest.action?.default_icon].filter(Boolean);
    assert.deepEqual(Object.keys(manifest.icons), ["16", "32", "48", "128"]);
    for (const icons of sets) {
      for (const [size, file] of Object.entries(icons)) {
        const { width, height } = pngSize(path.join(folder, file));
        assert.equal(width, Number(size), `${file} width`);
        assert.equal(height, Number(size), `${file} height`);
      }
    }
  });
}

test("chrome's toolbar button uses the 16 and 32 icons", () => {
  const manifest = require("../chrome/manifest.json");
  assert.deepEqual(manifest.action.default_icon, { 16: "icons/icon-16.png", 32: "icons/icon-32.png" });
});

test("chrome and safari ship the same icon files", () => {
  for (const size of [16, 32, 48, 128]) {
    const chrome = fs.readFileSync(path.join(extensions.chrome, "icons", `icon-${size}.png`));
    const safari = fs.readFileSync(path.join(extensions.safari, "icons", `icon-${size}.png`));
    assert.ok(chrome.equals(safari), `icon-${size}.png differs`);
  }
});

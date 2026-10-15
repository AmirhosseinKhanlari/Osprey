const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const manifest = require("../chrome/manifest.json");

test("the manifest key yields the extension ID the host allows", () => {
  const der = Buffer.from(manifest.key, "base64");
  const hex = crypto.createHash("sha256").update(der).digest("hex").slice(0, 32);
  const id = [...hex].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join("");
  assert.equal(id, "hdaelhdfolkmnghifnpopgadkndofanj");
});

test("permissions are exactly what the design needs", () => {
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual([...manifest.permissions].sort(), ["alarms", "contextMenus", "cookies", "downloads", "nativeMessaging", "storage"]);
  assert.equal(manifest.background.service_worker, "background.js");
  assert.deepEqual(manifest.content_scripts[0].js, ["rules.js", "video-button.js", "content.js"]);
});

test("popup status text is announced to screen readers", () => {
  const html = require("node:fs").readFileSync(require("node:path").join(__dirname, "..", "chrome", "popup.html"), "utf8");
  assert.match(html, /<p id="status"[^>]*aria-live="polite"/);
});

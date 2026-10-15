const test = require("node:test");
const assert = require("node:assert/strict");
const manifest = require("../safari/Resources/manifest.json");

test("safari manifest loads the shared rules before each script", () => {
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.background.scripts, ["rules.js", "background.js"]);
  assert.equal(manifest.background.persistent, false);
  assert.deepEqual(manifest.content_scripts[0].js, ["rules.js", "video-button.js", "content.js"]);
  assert.deepEqual([...manifest.permissions].sort(), ["contextMenus", "cookies", "nativeMessaging", "storage"]);
});

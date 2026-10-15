const test = require("node:test");
const assert = require("node:assert/strict");
const R = require("../shared/rules.js");

const rules = { enabled: true, extensions: ["zip", "dmg", "r0*"], captureInPrivate: false };

test("extensionOf reads file names and URL paths", () => {
  assert.equal(R.extensionOf("/Users/me/Downloads/Xcode.XIP"), "xip");
  assert.equal(R.extensionOf("https://x.test/a/b.zip?token=1#top"), "zip");
  assert.equal(R.extensionOf("https://x.test/a/file%20name.dmg"), "dmg");
  assert.equal(R.extensionOf("https://x.test/download"), "");
  assert.equal(R.extensionOf(".hidden"), "");
  assert.equal(R.extensionOf(""), "");
});

test("matchesExtension supports trailing wildcards", () => {
  assert.ok(R.matchesExtension("r01", rules.extensions));
  assert.ok(R.matchesExtension("zip", rules.extensions));
  assert.ok(!R.matchesExtension("r1", rules.extensions));
  assert.ok(!R.matchesExtension("", rules.extensions));
});

test("shouldCaptureDownload applies every skip rule", () => {
  const item = { url: "https://x.test/a.zip", finalUrl: "https://cdn.test/a.zip", filename: "", incognito: false };
  assert.ok(R.shouldCaptureDownload(item, rules, 1000, 0));
  assert.ok(!R.shouldCaptureDownload(item, { ...rules, enabled: false }, 1000, 0));
  assert.ok(!R.shouldCaptureDownload({ ...item, finalUrl: "blob:https://x.test/1" }, rules, 1000, 0));
  assert.ok(!R.shouldCaptureDownload({ ...item, incognito: true }, rules, 1000, 0));
  assert.ok(R.shouldCaptureDownload({ ...item, incognito: true }, { ...rules, captureInPrivate: true }, 1000, 0));
  assert.ok(!R.shouldCaptureDownload(item, rules, 1000, 2000), "within the Option bypass window");
  assert.ok(!R.shouldCaptureDownload({ ...item, url: "https://x.test/page.html", finalUrl: "https://x.test/page.html" }, rules, 1000, 0));
  assert.ok(R.shouldCaptureDownload({ ...item, finalUrl: "https://x.test/get?id=1", filename: "/tmp/a.dmg" }, rules, 1000, 0));
});

test("shouldCaptureDownload also reads the link that redirected to a nameless URL", () => {
  // vikingfile.com/d/…/PPSA07631.7z → a storage URL without a name, served as application/octet-stream
  const item = { url: "https://host.test/d/abc/file.zip", finalUrl: "https://bucket.test/zFgvoua8v4?sig=1",
                 filename: "", mime: "application/octet-stream", incognito: false };
  assert.ok(R.shouldCaptureDownload(item, rules, 1000, 0));
  assert.ok(!R.shouldCaptureDownload({ ...item, url: "https://host.test/d/abc" }, rules, 1000, 0));
});

test("a storage URL that names its file in response-content-disposition counts by that name", () => {
  const signed = "https://bucket.test/zFgvoua8v4?response-content-disposition=attachment%3Bfilename%3DPPSA07631.zip&X-Amz-Expires=172800";
  assert.equal(R.dispositionName(signed), "PPSA07631.zip");
  assert.equal(R.dispositionName("https://b.test/x?response-content-disposition=attachment%3B%20filename%3D%22My%20File.zip%22"), "My File.zip");
  assert.equal(R.dispositionName("https://b.test/x?response-content-disposition=attachment%3B%20filename*%3DUTF-8%27%27r%C3%A9sum%C3%A9.zip"), "résumé.zip");
  assert.equal(R.dispositionName("https://b.test/x?a=1"), "");
  assert.equal(R.dispositionName("https://b.test/x?response-content-disposition=attachment%3Bfilename%3D..%2F..%2Fevil.zip"), "evil.zip");
  const item = { url: signed, finalUrl: signed, filename: "", mime: "application/octet-stream", incognito: false };
  assert.ok(R.shouldCaptureDownload(item, rules, 1000, 0));
  assert.equal(R.suggestedFilename(item), "PPSA07631.zip");
  assert.ok(R.shouldCaptureLink({ href: signed, hasDownloadAttribute: false }, rules, false, false));
});

test("suggestedFilename prefers Chrome's name, then the link's own", () => {
  assert.equal(R.suggestedFilename({ filename: "/dl/a.zip", url: "https://x.test/b.zip" }), "/dl/a.zip");
  assert.equal(R.suggestedFilename({ filename: "", url: "https://x.test/d/My%20File.7z", finalUrl: "https://cdn.test/x1" }), "My File.7z");
  assert.equal(R.suggestedFilename({ filename: "", url: "https://x.test/download", finalUrl: "https://cdn.test/x1" }), "");
});

test("shouldCaptureLink handles the download attribute and Option", () => {
  assert.ok(R.shouldCaptureLink({ href: "https://x.test/a.zip", hasDownloadAttribute: false }, rules, false, false));
  assert.ok(R.shouldCaptureLink({ href: "https://x.test/export", hasDownloadAttribute: true }, rules, false, false));
  assert.ok(!R.shouldCaptureLink({ href: "https://x.test/a.zip", hasDownloadAttribute: false }, rules, true, false));
  assert.ok(!R.shouldCaptureLink({ href: "https://x.test/a.zip", hasDownloadAttribute: false }, rules, false, true));
  assert.ok(!R.shouldCaptureLink({ href: "javascript:void(0)", hasDownloadAttribute: true }, rules, false, false));
});

test("captureMessage matches the v1 protocol and drops empty fields", () => {
  const message = R.captureMessage({ url: "https://x.test/a.zip", referrer: "", size: 0, cookies: "a=1", isPrivate: false, source: "menu" });
  assert.deepEqual(JSON.parse(JSON.stringify(message)),
    { v: 1, type: "capture", url: "https://x.test/a.zip", cookies: "a=1", private: false, source: "menu" });
  assert.deepEqual(R.helloMessage(), { v: 1, type: "hello" });
});

test("reply helpers", () => {
  assert.ok(R.wasTaken({ v: 1, ok: true, taken: true }));
  assert.ok(!R.wasTaken({ v: 1, ok: true, taken: false }));
  assert.ok(!R.wasTaken({ v: 1, ok: false, error: "unavailable" }));
  assert.ok(!R.wasTaken(null));
  assert.equal(R.cookieHeader([{ name: "a", value: "1" }, { name: "b", value: "2" }]), "a=1; b=2");
  assert.deepEqual(R.rulesFromHello({ v: 1, ok: true, rules }), { ...rules, videoButton: true });
  assert.equal(R.rulesFromHello({ v: 1, ok: false, error: "disabled" }), null);
});

test("defaults match the app's list", () => {
  assert.equal(R.HOST_NAME, "com.akhanlari.osprey.host");
  assert.equal(R.BYPASS_WINDOW_MS, 2000);
  assert.equal(R.HELLO_TIMEOUT_MS, 3000);
  assert.equal(R.CAPTURE_TIMEOUT_MS, 8000);
  assert.equal(R.DEFAULT_RULES.extensions.join(" "),
    "3gp 7z aac ace aif apk arj asf avi bin bz2 dmg exe gz gzip img iso lzh m4a m4v mkv mov mp3 mp4 mpa mpe mpeg mpg msi msu ogg ogv pdf pkg plj pps ppt qt r0* r1* ra rar rm rmvb sea sit sitx tar tif tiff wav webm wma wmv xip xz z zip");
});

test("extensionOf keeps ?/# in plain file names and strips them only from URLs", () => {
  assert.equal(R.extensionOf("report#1.zip"), "zip");
  assert.equal(R.extensionOf("C:\\dl\\b.ZIP"), "zip");
  assert.equal(R.extensionOf("file.tar.gz"), "gz");
  assert.equal(R.extensionOf("https://x.test/dir/"), "");
  assert.equal(R.extensionOf("https://x.test/a.zip#frag"), "zip");
});

test("extensionForMime maps known types, ignores parameters and case, and is frozen", () => {
  assert.ok(Object.isFrozen(R.MIME_EXTENSIONS));
  assert.equal(R.extensionForMime("application/zip; charset=binary"), "zip");
  assert.equal(R.extensionForMime("APPLICATION/PDF"), "pdf");
  assert.equal(R.extensionForMime("application/vnd.apple.installer+xml"), "pkg");
  assert.equal(R.extensionForMime("audio/x-m4a"), "m4a");
  assert.equal(R.extensionForMime("application/octet-stream"), "");
  assert.equal(R.extensionForMime("constructor"), "");
  assert.equal(R.extensionForMime(""), "");
  assert.equal(R.extensionForMime(undefined), "");
});

test("shouldCaptureDownload captures when the file name, URL or MIME extension is listed", () => {
  const base = { incognito: false, filename: "", mime: "application/zip; charset=binary" };
  assert.ok(R.shouldCaptureDownload({ ...base, finalUrl: "https://x.test/get?id=1" }, rules, 1000, 0));
  assert.ok(!R.shouldCaptureDownload({ ...base, finalUrl: "https://x.test/get?id=1", mime: "application/octet-stream" }, rules, 1000, 0));
  // An unlisted URL or name extension no longer hides a listed MIME type (download.php, page.html serving a zip).
  assert.ok(R.shouldCaptureDownload({ ...base, finalUrl: "https://x.test/page.html" }, rules, 1000, 0), "MIME matches despite .html URL");
  assert.ok(R.shouldCaptureDownload({ ...base, finalUrl: "https://x.test/download.php", filename: "/tmp/download.php" }, rules, 1000, 0));
  // A listed name wins even when the URL and MIME say otherwise.
  assert.ok(R.shouldCaptureDownload({ ...base, finalUrl: "https://x.test/get.php", filename: "/tmp/a.zip", mime: "text/html" }, rules, 1000, 0));
  // Nothing listed anywhere: not captured.
  assert.ok(!R.shouldCaptureDownload({ ...base, finalUrl: "https://x.test/page.html", filename: "/tmp/page.html", mime: "text/html" }, rules, 1000, 0));
});

test("shouldCaptureDownload takes the URL extension when the file name has none", () => {
  const item = { finalUrl: "https://x.test/a.zip", filename: "/tmp/download", mime: "", incognito: false };
  assert.ok(R.shouldCaptureDownload(item, rules, 1000, 0));
});

test("matchesExtension ignores lone or empty wildcards and never throws on bad patterns", () => {
  assert.ok(!R.matchesExtension("zip", ["*"]));
  assert.ok(!R.matchesExtension("zip", [""]));
  assert.ok(!R.matchesExtension("r", ["r0*"]), "r0* does not match bare r");
  assert.ok(R.matchesExtension("r05", ["r0*"]));
  assert.ok(!R.matchesExtension("zip", "zip"));
  assert.ok(!R.matchesExtension("zip", undefined));
});

test("rulesFromHello normalizes what the host sends", () => {
  const defaults = R.DEFAULT_RULES.extensions;
  assert.deepEqual(R.rulesFromHello({ ok: true, rules: { enabled: true, captureInPrivate: true } }),
    { enabled: true, extensions: defaults, captureInPrivate: true, videoButton: true });
  assert.deepEqual(R.rulesFromHello({ ok: true, rules: { enabled: true, extensions: "zip" } }),
    { enabled: true, extensions: defaults, captureInPrivate: false, videoButton: true });
  assert.deepEqual(R.rulesFromHello({ ok: true, rules: { enabled: true, extensions: ["zip", 5, null, "dmg", {}] } }),
    { enabled: true, extensions: ["zip", "dmg"], captureInPrivate: false, videoButton: true });
  assert.equal(R.rulesFromHello({ ok: true, rules: { enabled: "yes", extensions: ["zip"] } }), null);
  assert.equal(R.rulesFromHello({ ok: true, rules: { extensions: ["zip"] } }), null);
  assert.equal(R.rulesFromHello({ ok: true, rules: "nope" }), null);
  assert.equal(R.rulesFromHello({ ok: true, rules: { enabled: true, captureInPrivate: "yes" } }).captureInPrivate, false);
});

test("rulesFromHello keeps videoButton and defaults it to true", () => {
  assert.equal(R.rulesFromHello({ ok: true, rules: { enabled: true } }).videoButton, true);
  assert.equal(R.rulesFromHello({ ok: true, rules: { enabled: true, videoButton: false } }).videoButton, false);
  assert.equal(R.rulesFromHello({ ok: true, rules: { enabled: true, videoButton: "no" } }).videoButton, true);
  assert.equal(R.DEFAULT_RULES.videoButton, true);
});

const vp = { width: 1280, height: 800 };
const box = (left, top, width, height) => ({ left, top, width, height, right: left + width, bottom: top + height });

test("shouldOfferVideoButton: size, visibility and the setting", () => {
  assert.equal(R.VIDEO_MIN_WIDTH, 240);
  assert.equal(R.VIDEO_MIN_HEIGHT, 135);
  const on = { enabled: true, videoButton: true };
  assert.ok(R.shouldOfferVideoButton(box(10, 10, 640, 360), vp, on));
  assert.ok(R.shouldOfferVideoButton(box(10, 10, 240, 135), vp, on));
  assert.ok(R.shouldOfferVideoButton(box(10, 10, 640, 360), vp, { enabled: true }), "missing videoButton means on");
  assert.ok(!R.shouldOfferVideoButton(box(10, 10, 239, 360), vp, on));
  assert.ok(!R.shouldOfferVideoButton(box(10, 10, 640, 134), vp, on));
  assert.ok(!R.shouldOfferVideoButton(box(10, 2000, 640, 360), vp, on), "below the viewport");
  assert.ok(!R.shouldOfferVideoButton(box(-700, 10, 640, 360), vp, on), "left of the viewport");
  assert.ok(!R.shouldOfferVideoButton(box(10, 10, 640, 360), vp, { enabled: true, videoButton: false }));
  assert.ok(!R.shouldOfferVideoButton(box(10, 10, 640, 360), vp, { enabled: false, videoButton: true }));
  assert.ok(!R.shouldOfferVideoButton(box(10, 10, 640, 360), vp, null));
});

test("mediaMessage matches the v1 protocol and drops empty fields", () => {
  assert.deepEqual(JSON.parse(JSON.stringify(R.mediaMessage({ url: "https://x.test/v", title: "T", cookies: "a=1", isPrivate: true, source: "menu" }))),
    { v: 1, type: "media", url: "https://x.test/v", title: "T", cookies: "a=1", private: true, source: "menu" });
  assert.deepEqual(JSON.parse(JSON.stringify(R.mediaMessage({ url: "https://x.test/v", title: "", cookies: "" }))),
    { v: 1, type: "media", url: "https://x.test/v", private: false, source: "button" });
});

test("buttonTargetUrl: the video's own page only on the sender's own origin; otherwise null", () => {
  const channel = "https://www.youtube.com/@chan";
  assert.equal(R.buttonTargetUrl("https://www.youtube.com/watch?v=abc", channel), "https://www.youtube.com/watch?v=abc");
  assert.equal(R.buttonTargetUrl("https://www.youtube.com:443/watch?v=abc", channel), "https://www.youtube.com:443/watch?v=abc", "default port");
  assert.equal(R.buttonTargetUrl("https://b.github.io/v", "https://a.github.io/page"), null, "shared host suffix");
  assert.equal(R.buttonTargetUrl("http://example.com/watch", "https://example.com/page"), null, "https page, http target");
  assert.equal(R.buttonTargetUrl("https://example.com:8443/watch", "https://example.com/page"), null, "another port");
  assert.equal(R.buttonTargetUrl("https://m.youtube.com/watch?v=abc", channel), null, "same site, other host");
  assert.equal(R.buttonTargetUrl("https://evil.test/x", "https://frame.example.com/embed"), null);
  assert.equal(R.buttonTargetUrl("javascript:1", channel), null);
  assert.equal(R.buttonTargetUrl(undefined, channel), null);
  assert.equal(R.buttonTargetUrl("https://example.com/watch", undefined), null, "no sender URL");
});

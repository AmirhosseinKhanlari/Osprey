const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const tick = async (n = 6) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };
const root = path.join(__dirname, "..");

// Loads a content script with a stub OspreyVideoButton and reports how it is attached.
// `flag`: Chrome's chrome.extension.inIncognitoContext (left out when undefined).
function load(kind, stored, reply = { taken: true }, priv = false, ctx = undefined, flag = undefined) {
  const attaches = [];
  const sent = [];
  let changed = [];
  const handle = { detached: 0, refreshed: 0, detach() { this.detached++; }, refresh() { this.refreshed++; } };
  const api = {
    ...(kind === "safari" ? { extension: { inIncognitoContext: priv } } : {}),
    ...(kind === "chrome" && flag !== undefined ? { extension: { inIncognitoContext: flag } } : {}),
    storage: { local: { get: async () => (stored ? { rules: stored } : {}) }, onChanged: { addListener: (fn) => changed.push(fn) } },
    runtime: { id: "x", sendMessage: (m) => { sent.push(m); if (m.type === "context") return Promise.resolve(ctx === undefined ? { incognito: priv } : ctx); return Promise.resolve(m.type === "media-from-button" ? reply : undefined); } },
  };
  const window = { addEventListener() {} };
  const context = vm.createContext({
    browser: api, chrome: api, URL, window, Element: class {},
    location: { href: "https://example.com/watch" },
    navigator: { userAgent: "UA" }, setTimeout, clearTimeout,
    document: { title: "Clip", cookie: "a=b", addEventListener() {} },
  });
  vm.runInContext(fs.readFileSync(path.join(root, "shared/rules.js"), "utf8"), context);
  context.OspreyVideoButton = { attach: (d, w, send, getRules, mayShow) => { attaches.push({ send, getRules, mayShow }); return handle; } };
  const file = kind === "chrome" ? "chrome/content.js" : "safari/Resources/content.js";
  vm.runInContext(fs.readFileSync(path.join(root, file), "utf8"), context, { filename: file });
  // An eligible video shows up: the pill appears when the button is attached and its gate (if any) allows it.
  const videoAppears = () => {
    const live = attaches[attaches.length - 1];
    if (!live || handle.detached >= attaches.length) return false;
    return typeof live.mayShow === "function" ? live.mayShow() === true : true;
  };
  const contexts = () => sent.filter((m) => m.type === "context").length;
  return { attaches, sent, handle, videoAppears, contexts, change: (rules) => changed.forEach((fn) => fn({ rules: { newValue: rules } }, "local")) };
}

for (const kind of ["chrome", "safari"]) {
  test(`${kind}: attaches only when the cached rules allow the button`, async () => {
    const off = load(kind, { enabled: true, videoButton: false });
    await tick();
    assert.equal(off.attaches.length, 0);
    const disabled = load(kind, { enabled: false, videoButton: true });
    await tick();
    assert.equal(disabled.attaches.length, 0);
    const unknown = load(kind, null);
    await tick();
    assert.equal(unknown.attaches.length, 0);
    const on = load(kind, { enabled: true });
    await tick();
    assert.equal(on.attaches.length, 1);
  });

  test(`${kind}: the button sends media-from-button with url and title; rules changes attach and detach`, async () => {
    const env = load(kind, { enabled: true, videoButton: true });
    await tick();
    assert.equal(JSON.stringify(await env.attaches[0].send()), JSON.stringify({ taken: true }));
    const msg = env.sent.find((m) => m.type === "media-from-button");
    assert.equal(msg.url, "https://example.com/watch");
    assert.equal(msg.title, "Clip");
    env.change({ enabled: true, videoButton: false });
    assert.equal(env.handle.detached, 1);
    env.change({ enabled: true, videoButton: true });
    assert.equal(env.attaches.length, 2);
  });

  test(`${kind}: the button sends the target video-button resolved, not the page`, async () => {
    const env = load(kind, { enabled: true, videoButton: true });
    await tick();
    await env.attaches[0].send({}, { url: "https://www.youtube.com/watch?v=abc", title: "A clip", page: false });
    const msg = env.sent.find((m) => m.type === "media-from-button");
    assert.equal(msg.url, "https://www.youtube.com/watch?v=abc");
    assert.equal(msg.title, "A clip");
    await env.attaches[0].send({}, { url: "https://www.youtube.com/watch?v=def", page: false });
    assert.equal(env.sent.filter((m) => m.type === "media-from-button")[1].title, undefined);
  });

  test(`${kind}: a refused link is reported as no-link`, async () => {
    const env = load(kind, { enabled: true }, { taken: false, reason: "no-link" });
    await tick();
    assert.equal(JSON.stringify(await env.attaches[0].send({}, { url: "https://example.com/v/1" })), JSON.stringify({ taken: false, reason: "no-link" }));
  });

  test(`${kind}: hidden in a private context unless captureInPrivate`, async () => {
    const blocked = load(kind, { enabled: true }, { taken: true }, true);
    await tick();
    assert.equal(blocked.videoAppears(), false);
    await tick();
    assert.equal(blocked.videoAppears(), false);
    const allowed = load(kind, { enabled: true, captureInPrivate: true }, { taken: true }, true);
    await tick();
    assert.equal(allowed.attaches.length, 1);
    assert.equal(allowed.videoAppears(), true);
  });

  test(`${kind}: an unanswered privacy question counts as private`, async () => {
    const env = load(kind, { enabled: true }, { taken: true }, false, null);
    await tick();
    env.videoAppears();
    await tick();
    assert.equal(env.videoAppears(), kind !== "chrome"); // Safari knows from its own API
  });

  test(`${kind}: a failed send resolves {taken:false}`, async () => {
    const env = load(kind, { enabled: true }, null);
    await tick();
    assert.equal(JSON.stringify(await env.attaches[0].send()), JSON.stringify({ taken: false }));
  });
}

// Ledger 44: Chrome asks the background only when it must, and only once.
test("chrome: a boolean inIncognitoContext is used and the background is never asked", async () => {
  const normal = load("chrome", { enabled: true }, { taken: true }, false, undefined, false);
  await tick();
  assert.equal(normal.attaches.length, 1);
  assert.equal(normal.videoAppears(), true);
  await tick();
  assert.equal(normal.contexts(), 0);
  const incognito = load("chrome", { enabled: true }, { taken: true }, false, undefined, true);
  await tick();
  assert.equal(incognito.videoAppears(), false);
  await tick();
  assert.equal(incognito.contexts(), 0);
  const allowed = load("chrome", { enabled: true, captureInPrivate: true }, { taken: true }, false, undefined, true);
  await tick();
  assert.equal(allowed.videoAppears(), true);
});

test("chrome: without the flag, the context question waits for the first eligible video and is asked once", async () => {
  const env = load("chrome", { enabled: true });
  await tick();
  assert.equal(env.contexts(), 0);                    // nothing asked on load
  assert.equal(env.videoAppears(), false);            // not known yet: no pill
  assert.equal(env.contexts(), 1);
  assert.equal(env.videoAppears(), false);            // still waiting: not asked again
  assert.equal(env.contexts(), 1);
  await tick();
  assert.equal(env.videoAppears(), true);             // answered: a normal window
  assert.equal(env.contexts(), 1);
});

test("chrome: the question is never asked when the rules hide the pill or allow private windows", async () => {
  for (const rules of [{ enabled: true, videoButton: false }, { enabled: false }, null]) {
    const env = load("chrome", rules);
    await tick();
    env.videoAppears();
    await tick();
    assert.equal(env.contexts(), 0);
  }
  const anyWindow = load("chrome", { enabled: true, captureInPrivate: true });
  await tick();
  assert.equal(anyWindow.videoAppears(), true);
  await tick();
  assert.equal(anyWindow.contexts(), 0);
});

test("chrome: an answer of private removes the button", async () => {
  const env = load("chrome", { enabled: true }, { taken: true }, true);
  await tick();
  assert.equal(env.videoAppears(), false);
  await tick();
  assert.equal(env.handle.detached, 1);
});

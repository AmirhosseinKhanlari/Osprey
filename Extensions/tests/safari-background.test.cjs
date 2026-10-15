const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const dir = path.join(__dirname, "..", "safari", "Resources");
const RULES = { enabled: true, extensions: ["zip"], captureInPrivate: true };
const tick = async (n = 8) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

function load(opts = {}) {
  const calls = [];
  const rec = (name, ...a) => calls.push([name, ...a]);
  const listeners = {};
  const localStore = { rules: opts.rules || RULES };
  const clock = { t: 1000000 };
  const event = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });
  const browser = {
    runtime: {
      onMessage: event("onMessage"), onInstalled: event("onInstalled"),
      async sendNativeMessage(id, message) {
        rec("native", message.type, message);
        const r = (opts.native || (() => undefined))(message);
        if (r === undefined) return new Promise(() => {});
        return r;
      },
    },
    storage: { local: { async get(k) { return k in localStore ? { [k]: localStore[k] } : {}; }, async set(o) { Object.assign(localStore, o); } } },
    contextMenus: { onClicked: event("onClicked"), async removeAll() { rec("menu.removeAll"); }, create(o) { rec("menu.create", o.id, o); } },
    tabs: { async create(o) { rec("tabs.create", o.url); if (opts.tabsFail) throw new Error("x"); } },
  };
  if (!opts.noCookies) {
    browser.cookies = { async getAll(q) { rec("getAll", q); return (opts.cookies || (() => []))(q); } };
  }
  const context = vm.createContext({
    browser, navigator: { userAgent: "UA" }, URL,
    Date: { now: () => clock.t },
    setTimeout: () => 0, clearTimeout() {},
  });
  vm.runInContext(fs.readFileSync(path.join(dir, "rules.js"), "utf8"), context);
  vm.runInContext(fs.readFileSync(path.join(dir, "background.js"), "utf8"), context, { filename: "background.js" });
  return { calls, listeners, localStore, clock,
    count: (n) => calls.filter((c) => c[0] === n).length,
    sentCapture: () => calls.find((c) => c[0] === "native" && c[1] === "capture")[2] };
}

const ok = (m) => (m.type === "capture" ? { ok: true, taken: false } : { ok: true, rules: RULES });
const cap = (extra = {}) => ({ type: "capture", url: "https://example.com/a.zip", pageUrl: "https://example.com/page", cookies: "page=1", source: "auto", ...extra });
const send = (env, msg, sender = {}) => env.listeners.onMessage(msg, sender);

test("capture replies {taken} and uses the cookie API", async () => {
  const env = load({ native: (m) => (m.type === "capture" ? { ok: true, taken: true } : { ok: true, rules: RULES }), cookies: () => [{ name: "s", value: "1" }] });
  assert.equal(JSON.stringify(await send(env, cap())), JSON.stringify({ taken: true }));
  assert.equal(env.sentCapture().cookies, "s=1");
});

test("an empty cookie result never falls back to document.cookie", async () => {
  const env = load({ native: ok, cookies: () => [] });
  await send(env, cap());
  assert.equal(env.sentCapture().cookies, undefined);
});

test("cookie API throwing, cross-origin link: no Cookie", async () => {
  const env = load({ native: ok, cookies: () => { throw new Error("x"); } });
  await send(env, cap({ url: "https://cdn.other.com/a.zip" }));
  assert.equal(env.sentCapture().cookies, undefined);
});

test("cookie API missing, same-origin link: document.cookie is used", async () => {
  const env = load({ native: ok, noCookies: true });
  await send(env, cap());
  assert.equal(env.sentCapture().cookies, "page=1");
});

test("cookie API missing, cross-origin link: no Cookie", async () => {
  const env = load({ native: ok, noCookies: true });
  await send(env, cap({ url: "https://cdn.other.com/a.zip" }));
  assert.equal(env.sentCapture().cookies, undefined);
});

test("private flag comes from sender.tab.incognito when available", async () => {
  const env = load({ native: ok });
  await send(env, cap({ isPrivate: false }), { tab: { incognito: true } });
  assert.equal(env.sentCapture().private, true);
  const env2 = load({ native: ok });
  await send(env2, cap({ isPrivate: true }), {});
  assert.equal(env2.sentCapture().private, true);
});

test("rules requests are throttled to one hello per 60 s and answered from cache", async () => {
  const env = load({ native: ok });
  await tick();
  const hellos = () => env.calls.filter((c) => c[0] === "native" && c[1] === "hello").length;
  assert.equal(hellos(), 1); // startup refresh
  const cached = await send(env, { type: "rules" });
  assert.equal(hellos(), 1);
  assert.equal(cached.enabled, true);
  env.clock.t += 61000;
  await send(env, { type: "rules" });
  assert.equal(hellos(), 2);
});

test("menu is rebuilt with removeAll then create; a failing tabs.create is caught", async () => {
  const env = load({ native: ok, tabsFail: true });
  await tick();
  assert.deepEqual(env.calls.map((c) => c[0]).filter((n) => n.startsWith("menu.")), ["menu.removeAll", "menu.create", "menu.create"]);
  await env.listeners.onClicked({ menuItemId: "osprey-download", linkUrl: "https://example.com/a.zip" }, { incognito: false });
  assert.equal(env.count("tabs.create"), 1);
});

// Safari's cookie API only reads the normal session's store, so a private tab must never send those cookies.
test("private tab: never the normal-session cookies; only same-origin document.cookie", async () => {
  const env = load({ native: ok, cookies: () => [{ name: "normal", value: "1" }] });
  await send(env, cap(), { tab: { incognito: true } });
  assert.equal(env.count("getAll"), 0);
  assert.equal(env.sentCapture().cookies, "page=1");
  const cross = load({ native: ok, cookies: () => [{ name: "normal", value: "1" }] });
  await send(cross, cap({ url: "https://cdn.other.com/a.zip" }), { tab: { incognito: true } });
  assert.equal(cross.count("getAll"), 0);
  assert.equal(cross.sentCapture().cookies, undefined);
});

test("private menu capture sends no cookies", async () => {
  const env = load({ native: ok, cookies: () => [{ name: "normal", value: "1" }] });
  await env.listeners.onClicked({ menuItemId: "osprey-download", linkUrl: "https://example.com/a.zip", pageUrl: "https://example.com/" },
    { incognito: true });
  assert.equal(env.count("getAll"), 0);
  assert.equal(env.sentCapture().cookies, undefined);
  assert.equal(env.sentCapture().private, true);
});

// Task 10: the "Download video" menu item and the floating button's message.
const mediaOk = (taken, rules = RULES) => (m) => (m.type === "media" ? { ok: true, taken } : { ok: true, rules });
const sentMedia = (env) => env.calls.find((c) => c[0] === "native" && c[1] === "media")?.[2];
const videoClick = (env, info, tab = { incognito: false, title: "Page title" }) =>
  env.listeners.onClicked({ menuItemId: "osprey-video", pageUrl: "https://example.com/watch", ...info }, tab);
const fromButton = (env, extra = {}, sender = { tab: { incognito: false }, url: "https://example.com/watch" }) =>
  send(env, { type: "media-from-button", url: "https://example.com/watch", title: "Clip", cookies: "page=1", ...extra }, sender);
const plain = (v) => JSON.parse(JSON.stringify(v));

test("both menu items exist; the video one has its own contexts", async () => {
  const env = load({ native: mediaOk(true) });
  await tick();
  const created = env.calls.filter((c) => c[0] === "menu.create");
  assert.deepEqual(created.map((c) => c[1]), ["osprey-download", "osprey-video"]);
  assert.equal(created[1][2].title, "Download video with Osprey");
  assert.deepEqual(plain(created[1][2].contexts), ["page", "video", "frame", "link"]);
});

test("video menu click sends media with link, then frame, then page URL and the cookie API's cookies", async () => {
  const cases = [
    [{ linkUrl: "https://example.com/l", frameUrl: "https://example.com/f" }, "https://example.com/l"],
    [{ frameUrl: "https://example.com/f" }, "https://example.com/f"],
    [{}, "https://example.com/watch"],
  ];
  for (const [info, expected] of cases) {
    const env = load({ native: mediaOk(true), cookies: () => [{ name: "s", value: "1" }] });
    await videoClick(env, info);
    const sent = sentMedia(env);
    assert.equal(sent.type, "media");
    assert.equal(sent.url, expected);
    assert.equal(sent.source, "menu");
    assert.equal(sent.title, "Page title");
    assert.equal(sent.cookies, "s=1");
    assert.equal(sent.private, false);
  }
});

test("private video menu click never sends the normal session's cookies", async () => {
  const env = load({ native: mediaOk(true), cookies: () => [{ name: "normal", value: "1" }] });
  await videoClick(env, {}, { incognito: true, title: "T" });
  assert.equal(env.count("getAll"), 0);
  assert.equal(sentMedia(env).cookies, undefined);
  assert.equal(sentMedia(env).private, true);
});

test("video menu ignores non-http URLs and a private tab when captureInPrivate is off", async () => {
  const env = load({ native: mediaOk(true) });
  await videoClick(env, { pageUrl: "safari-extension://x" });
  assert.equal(sentMedia(env), undefined);
  const off = { ...RULES, captureInPrivate: false };
  const priv = load({ native: mediaOk(true, off), rules: off });
  await videoClick(priv, {}, { incognito: true, title: "T" });
  assert.equal(sentMedia(priv), undefined);
});

test("media-from-button replies {taken} and scopes cookies like capture", async () => {
  const env = load({ native: mediaOk(true), cookies: () => [{ name: "s", value: "1" }] });
  assert.deepEqual(plain(await fromButton(env)), { taken: true });
  assert.equal(sentMedia(env).source, "button");
  assert.equal(sentMedia(env).title, "Clip");
  assert.equal(sentMedia(env).cookies, "s=1");
  const declined = load({ native: mediaOk(false) });
  assert.deepEqual(plain(await fromButton(declined)), { taken: false });
});

test("media-from-button: cookie API missing falls back to same-origin document.cookie; private tabs too", async () => {
  const env = load({ native: mediaOk(true), noCookies: true });
  await fromButton(env);
  assert.equal(sentMedia(env).cookies, "page=1");
  const priv = load({ native: mediaOk(true), cookies: () => [{ name: "normal", value: "1" }] });
  await fromButton(priv, {}, { tab: { incognito: true }, url: "https://example.com/watch" });
  assert.equal(priv.count("getAll"), 0);
  assert.equal(sentMedia(priv).cookies, "page=1");
  assert.equal(sentMedia(priv).private, true);
});

test("media-from-button refuses non-http URLs and private tabs when captureInPrivate is off", async () => {
  const env = load({ native: mediaOk(true) });
  assert.deepEqual(plain(await fromButton(env, { url: "javascript:1" }, { tab: { incognito: false }, url: "https://example.com/watch" })), { taken: false, reason: "no-link" });
  const off = { ...RULES, captureInPrivate: false };
  const priv = load({ native: mediaOk(true, off), rules: off });
  assert.deepEqual(plain(await fromButton(priv, {}, { tab: { incognito: true }, url: "https://example.com/watch" })), { taken: false });
  assert.equal(sentMedia(priv), undefined);
});

test("media-from-button needs a tab, and refuses (no-link) a URL that isn't the sender's origin, or no sender URL", async () => {
  const env = load({ native: mediaOk(true), noCookies: true });
  assert.deepEqual(plain(await send(env, { type: "media-from-button", url: "https://example.com/watch", cookies: "page=1" }, {})), { taken: false });
  assert.equal(sentMedia(env), undefined);
  const cases = [
    ["https://example.com/watch", "https://frame.other.com/e"],    // another site: never swapped for the frame's URL
    ["https://b.github.io/v", "https://a.github.io/page"],         // a shared host suffix
    ["http://example.com/watch", "https://example.com/page"],      // https page, http target
    ["https://m.youtube.com/watch?v=abc", "https://www.youtube.com/@chan"], // same site, other origin
    [undefined, "https://example.com/page"],                       // no URL from the button
    ["https://example.com/watch", undefined],                      // no sender URL
  ];
  for (const [url, senderUrl] of cases) {
    const each = load({ native: mediaOk(true), noCookies: true });
    assert.deepEqual(plain(await send(each, { type: "media-from-button", url, cookies: "page=1" }, { tab: {}, url: senderUrl })),
      { taken: false, reason: "no-link" }, `${url} from ${senderUrl}`);
    assert.equal(sentMedia(each), undefined, "nothing is sent to Osprey");
  }
});

test("media-from-button sends the video's own page on the sender's origin, with its document.cookie", async () => {
  const env = load({ native: mediaOk(true), noCookies: true });
  await send(env, { type: "media-from-button", url: "https://www.youtube.com/watch?v=abc", title: "A clip", cookies: "page=1" },
    { tab: {}, url: "https://www.youtube.com/@chan" });
  assert.equal(sentMedia(env).url, "https://www.youtube.com/watch?v=abc");
  assert.equal(sentMedia(env).title, "A clip");
  assert.equal(sentMedia(env).cookies, "page=1", "same origin as the sender");
  const api = load({ native: mediaOk(true), cookies: () => [{ name: "s", value: "1" }] });
  await send(api, { type: "media-from-button", url: "https://www.youtube.com/watch?v=abc", cookies: "page=1" },
    { tab: { incognito: false }, url: "https://www.youtube.com/@chan" });
  assert.equal(sentMedia(api).cookies, "s=1");
});

test("video menu falls back to the next http URL when the link is not http", async () => {
  const env = load({ native: mediaOk(true) });
  await videoClick(env, { linkUrl: "javascript:void(0)", frameUrl: "about:blank" });
  assert.equal(sentMedia(env).url, "https://example.com/watch");
});

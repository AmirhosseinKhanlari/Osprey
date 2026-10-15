const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const dir = path.join(__dirname, "..", "chrome");
const RULES = { enabled: true, extensions: ["zip"], captureInPrivate: true };
const tick = async (n = 8) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

function deferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}

// Builds a fake chrome, loads background.js into a fresh vm context and returns handles for the test.
function load(opts = {}) {
  const calls = [];
  const rec = (name, ...args) => calls.push([name, ...args]);
  const listeners = {};
  const store = { ...(opts.stored || {}) };
  const localStore = { rules: RULES, ...(opts.local || {}) };
  const timers = [];
  const downloadsState = opts.downloads || {}; // id -> {state, paused}
  let nextId = 100;

  const event = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });
  const chrome = {
    runtime: {
      id: "ext-id",
      lastError: undefined,
      onMessage: event("onMessage"),
      onInstalled: event("onInstalled"),
      onStartup: event("onStartup"),
      sendNativeMessage(host, message, cb) {
        rec("native", message.type, message);
        const reply = (opts.native || (() => undefined))(message);
        if (reply !== undefined) setImmediate(() => cb(reply));
      },
    },
    downloads: {
      onCreated: event("onCreated"),
      onChanged: event("onChanged"),
      async pause(id) {
        rec("pause", id);
        if (opts.pauseFails) throw new Error("gone");
        // Chrome accepts pause() on a download that is already finishing, but it doesn't pause it.
        const after = opts.afterPause || { state: "in_progress", paused: true, bytesReceived: 10, totalBytes: 100 };
        downloadsState[id] = { ...after };
      },
      async resume(id) { rec("resume", id); },
      async cancel(id) { rec("cancel", id); },
      async erase(q) { rec("erase", q.id); },
      async search(q) { rec("search", q.id); return downloadsState[q.id] ? [{ id: q.id, ...(opts.items || {})[q.id], ...downloadsState[q.id] }] : []; },
      async download(o) {
        rec("download", o.url);
        if (opts.downloadFails) throw new Error("blocked");
        return nextId++;
      },
    },
    cookies: {
      async getAll(q) { rec("getAll", q); return (opts.cookies || (() => []))(q); },
      async getAllCookieStores() { return opts.stores || [{ id: "0", tabIds: [1] }]; },
    },
    storage: {
      local: {
        async get(keys) {
          const out = {};
          for (const k of [].concat(keys)) if (k in localStore) out[k] = localStore[k];
          return out;
        },
        async set(obj) { Object.assign(localStore, obj); },
      },
      session: {
        async get(keys) {
          const out = {}; // snapshot at call time, like a read that was already in flight
          for (const k of [].concat(keys)) if (k in store) out[k] = store[k];
          if (opts.getDeferred) await opts.getDeferred.promise;
          if (opts.getFails) throw new Error("storage");
          return out;
        },
        async set(obj) {
          if (opts.setFailsFor && Object.keys(obj).some((k) => opts.setFailsFor.includes(k))) throw new Error("quota");
          Object.assign(store, obj);
        },
      },
    },
    action: {
      async setBadgeText(o) { rec("badge", o.text); if (opts.badgeFails) throw new Error("badge"); },
      async setBadgeBackgroundColor() { if (opts.badgeFails) throw new Error("badge"); },
    },
    contextMenus: {
      onClicked: event("onClicked"),
      async removeAll() { rec("menu.removeAll"); },
      create(o) { rec("menu.create", o.id, o); },
    },
    alarms: {
      async get() { return opts.alarm; },
      create(name, info) { rec("alarm.create", name, info); if (opts.alarmCreateFails) return Promise.reject(new Error("alarms")); },
      onAlarm: event("onAlarm"),
    },
  };

  const context = vm.createContext({
    chrome,
    navigator: { userAgent: "UA" },
    URL,
    setTimeout: (fn, ms) => { timers.push({ fn, ms, cleared: false }); return timers.length - 1; },
    clearTimeout: (id) => { if (timers[id]) timers[id].cleared = true; },
    importScripts: (file) => vm.runInContext(fs.readFileSync(path.join(dir, file), "utf8"), context, { filename: file }),
  });
  context.self = context;
  vm.runInContext(fs.readFileSync(path.join(dir, "background.js"), "utf8"), context, { filename: "background.js" });

  return {
    calls, listeners, store, localStore,
    names: () => calls.map((c) => c[0]),
    count: (name) => calls.filter((c) => c[0] === name).length,
    fireTimers(ms) { for (const t of timers) if (!t.cleared && t.ms === ms) { t.cleared = true; t.fn(); } },
    chrome,
  };
}

const zipItem = (extra = {}) => ({ id: 7, url: "https://example.com/a.zip", filename: "/dl/a.zip", incognito: false, state: "in_progress", ...extra });
const takenReply = (m) => (m.type === "capture" ? { ok: true, taken: true } : { ok: true, rules: RULES });
const declinedReply = (m) => (m.type === "capture" ? { ok: true, taken: false } : { ok: true, rules: RULES });

test("taken: cancels and erases, never resumes", async () => {
  const env = load({ native: takenReply });
  await env.listeners.onCreated(zipItem());
  assert.deepEqual(env.names().filter((n) => ["pause", "cancel", "erase", "resume"].includes(n)), ["pause", "cancel", "erase"]);
});

test("not taken: resumes the download", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.count("resume"), 1);
  assert.equal(env.count("cancel"), 0);
});

test("reply timeout: resumes the download", async () => {
  const env = load({ native: () => undefined }); // the app never answers
  const done = env.listeners.onCreated(zipItem());
  await tick();
  env.fireTimers(8000);
  await done;
  assert.equal(env.count("resume"), 1);
  assert.equal(env.count("cancel"), 0);
});

test("badge/storage failure in setReachable still resumes (declined and unreachable)", async () => {
  const env = load({ native: declinedReply, badgeFails: true, setFailsFor: ["hostStatus"] });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.count("resume"), 1);
});

test("badge failure with taken reply still cancels", async () => {
  const env = load({ native: takenReply, badgeFails: true });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.count("cancel"), 1);
  assert.equal(env.count("resume"), 0);
});

test("cookie lookup throwing does not strand the paused download", async () => {
  const env = load({ native: declinedReply, cookies: () => { throw new Error("x"); } });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.count("resume"), 1);
});

test("a link that redirects to a nameless URL is captured with the link's name", async () => {
  const env = load({ native: takenReply });
  await env.listeners.onCreated(zipItem({ url: "https://host.example/d/abc/My%20File.zip", finalUrl: "https://bucket.example/zF1?sig=1",
                                          filename: "", mime: "application/octet-stream" }));
  assert.equal(env.count("pause"), 1);
  const capture = env.calls.find((c) => c[0] === "native" && c[1] === "capture")[2];
  assert.equal(capture.url, "https://bucket.example/zF1?sig=1");
  assert.equal(capture.filename, "My File.zip");
});

test("a download is captured once Chrome learns its name", async () => {
  const env = load({
    native: takenReply,
    downloads: { 7: { state: "in_progress", paused: false } },
    items: { 7: { url: "https://example.com/get?id=1", finalUrl: "https://example.com/get?id=1", filename: "/dl/report.zip",
                  incognito: false, mime: "application/octet-stream" } },
  });
  await env.listeners.onCreated(zipItem({ url: "https://example.com/get?id=1", filename: "", mime: "application/octet-stream" }));
  assert.equal(env.count("pause"), 0);                     // nothing to go on yet
  await env.listeners.onChanged({ id: 7, filename: { current: "/dl/report.zip" } });
  await tick();
  assert.equal(env.count("pause"), 1);
  assert.equal(env.count("cancel"), 1);                    // Osprey took it
  await env.listeners.onChanged({ id: 7, filename: { current: "/dl/report.zip" } });
  await tick();
  assert.equal(env.count("pause"), 1, "considered once");
});

test("a named download that doesn't match is left alone", async () => {
  const env = load({
    native: takenReply,
    downloads: { 7: { state: "in_progress", paused: false } },
    items: { 7: { url: "https://example.com/get?id=1", filename: "/dl/notes.txt", incognito: false } },
  });
  await env.listeners.onCreated(zipItem({ url: "https://example.com/get?id=1", filename: "" }));
  await env.listeners.onChanged({ id: 7, filename: { current: "/dl/notes.txt" } });
  await tick();
  assert.equal(env.count("pause"), 0);
});

test("non-matching extension is not paused", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onCreated(zipItem({ url: "https://example.com/a.txt", filename: "/dl/a.txt" }));
  assert.equal(env.count("pause"), 0);
});

test("ready rejection falls back to defaults without an unhandled rejection", async () => {
  const unhandled = [];
  const onUnhandled = (e) => unhandled.push(e);
  process.on("unhandledRejection", onUnhandled);
  try {
    const env = load({ native: declinedReply, getFails: true });
    await env.listeners.onCreated(zipItem());
    await tick();
    assert.equal(env.count("pause"), 1); // default rules include zip
    assert.deepEqual(unhandled, []);
  } finally {
    process.off("unhandledRejection", onUnhandled);
  }
});

test("a bypass right after wake beats a stale stored bypass", async () => {
  const gate = deferred();
  const env = load({ native: declinedReply, getDeferred: gate, stored: { bypassUntil: 1 } });
  const done = env.listeners.onCreated(zipItem());
  env.listeners.onMessage({ type: "bypass" }, {}, () => {});
  gate.resolve();
  await done;
  assert.equal(env.count("pause"), 0);
});

test("pending ids are recorded before asking the app and cleared afterwards", async () => {
  let during;
  let env;
  env = load({ native: (m) => { if (m.type === "capture") during = [...(env.store.pending || [])]; return declinedReply(m); } });
  await env.listeners.onCreated(zipItem());
  assert.deepEqual(during, [7]);
  assert.deepEqual([...env.store.pending], []);
});

test("on wake, leftover paused downloads are resumed; others are left alone", async () => {
  const env = load({
    stored: { pending: [11, 12, 13] },
    downloads: { 11: { state: "in_progress", paused: true }, 12: { state: "complete", paused: false }, 13: { state: "in_progress", paused: false } },
  });
  await tick();
  assert.deepEqual(env.calls.filter((c) => c[0] === "resume").map((c) => c[1]), [11]);
  assert.deepEqual([...env.store.pending], []);
});

test("onStartup also resumes leftovers", async () => {
  const env = load({ downloads: { 21: { state: "in_progress", paused: true } } });
  await tick();
  env.store.pending = [21];
  await env.listeners.onStartup();
  await tick();
  assert.equal(env.count("resume"), 1);
});

test("an in-flight download is not resumed by a recovery pass", async () => {
  let env;
  env = load({
    downloads: { 7: { state: "in_progress", paused: true } },
    native: (m) => { if (m.type === "capture") { env.listeners.onStartup(); } return m.type === "capture" ? undefined : { ok: true, rules: RULES }; },
  });
  const done = env.listeners.onCreated(zipItem());
  await tick();
  assert.equal(env.count("resume"), 0);
  env.fireTimers(8000);
  await done;
  assert.equal(env.count("resume"), 1);
});

test("menu-declined fallback download is not re-captured (byExtensionId)", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onClicked({ menuItemId: "osprey-download", linkUrl: "https://example.com/a.zip" }, { id: 1, incognito: false });
  assert.equal(env.count("download"), 1);
  await env.listeners.onCreated(zipItem({ byExtensionId: "ext-id" }));
  assert.equal(env.count("pause"), 0);
});

test("menu-declined fallback download is not re-captured (recorded id)", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onClicked({ menuItemId: "osprey-download", linkUrl: "https://example.com/a.zip" }, { id: 1, incognito: false });
  await env.listeners.onCreated(zipItem({ id: 100 })); // first id handed out by the fake
  assert.equal(env.count("pause"), 0);
});

test("a failing fallback download() is caught", async () => {
  const env = load({ native: declinedReply, downloadFails: true });
  await env.listeners.onClicked({ menuItemId: "osprey-download", linkUrl: "https://example.com/a.zip" }, { id: 1, incognito: false });
  assert.equal(env.count("download"), 1);
});

test("incognito download uses the incognito store's cookies", async () => {
  const env = load({
    native: declinedReply,
    stores: [{ id: "0", tabIds: [1] }, { id: "1", tabIds: [2] }],
    cookies: (q) => (q.storeId === "1" ? [{ name: "s", value: "private" }] : [{ name: "s", value: "normal" }]),
  });
  await env.listeners.onCreated(zipItem({ incognito: true }));
  const sent = env.calls.find((c) => c[0] === "native" && c[1] === "capture")[2];
  assert.equal(sent.cookies, "s=private");
  assert.equal(sent.private, true);
});

test("incognito menu click picks the store that holds the tab", async () => {
  const env = load({
    native: declinedReply,
    stores: [{ id: "0", tabIds: [1] }, { id: "5", tabIds: [2] }, { id: "6", tabIds: [3] }],
    cookies: (q) => [{ name: "store", value: q.storeId }],
  });
  await env.listeners.onClicked({ menuItemId: "osprey-download", linkUrl: "https://example.com/a.zip" }, { id: 3, incognito: true });
  const sent = env.calls.find((c) => c[0] === "native" && c[1] === "capture")[2];
  assert.equal(sent.cookies, "store=6");
});

test("incognito with no matching store sends no cookies", async () => {
  const env = load({ native: declinedReply, stores: [{ id: "0", tabIds: [1] }], cookies: () => [{ name: "a", value: "b" }] });
  await env.listeners.onCreated(zipItem({ incognito: true }));
  const sent = env.calls.find((c) => c[0] === "native" && c[1] === "capture")[2];
  assert.equal(sent.cookies, undefined);
  assert.equal(env.count("getAll"), 0);
});

test("normal download reads the default store without a storeId", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.calls.find((c) => c[0] === "getAll")[1].storeId, undefined);
});

test("alarm refreshes rules every minute; created idempotently", async () => {
  const env = load({ native: declinedReply });
  await tick();
  assert.equal(JSON.stringify(env.calls.find((c) => c[0] === "alarm.create").slice(1)), JSON.stringify(["osprey-refresh", { periodInMinutes: 1 }]));
  const before = env.count("native");
  await env.listeners.onAlarm({ name: "osprey-refresh" });
  assert.equal(env.count("native"), before + 1);
  const existing = load({ native: declinedReply, alarm: { name: "osprey-refresh" } });
  await tick();
  assert.equal(existing.count("alarm.create"), 0);
});

test("onInstalled clears menus before creating", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onInstalled();
  await tick();
  const order = env.names().filter((n) => n.startsWith("menu."));
  assert.deepEqual(order, ["menu.removeAll", "menu.create", "menu.create"]);
});

test("refresh message always replies, even if refresh throws", async () => {
  const env = load({ native: declinedReply, badgeFails: true, getFails: true });
  let reply;
  const keep = env.listeners.onMessage({ type: "refresh" }, {}, (r) => { reply = r; });
  assert.equal(keep, true);
  await tick(20);
  assert.ok(reply && typeof reply.status === "string" && typeof reply.enabled === "boolean");
});

const badges = (env) => env.calls.filter((c) => c[0] === "badge").map((c) => c[1]);
const refresh = async (env) => {
  let reply;
  env.listeners.onMessage({ type: "refresh" }, {}, (r) => { reply = r; });
  await tick(20);
  return reply;
};
const hello = (reply) => (m) => (m.type === "hello" ? reply : { ok: true, taken: false });

test("hello unreachable (null reply): '!' badge, status unreachable", async () => {
  const env = load({ native: hello(undefined) });
  const done = refresh(env);
  await tick();
  env.fireTimers(3000);
  const reply = await done;
  assert.equal(reply.status, "unreachable");
  assert.equal(env.store.hostStatus, "unreachable");
  assert.ok(badges(env).includes("!"));
});

test("hello unreachable (lastError): '!' badge", async () => {
  const env = load({ native: () => undefined });
  env.chrome.runtime.sendNativeMessage = (h, m, cb) => {
    env.chrome.runtime.lastError = { message: "Specified native messaging host not found." };
    setImmediate(() => { cb(undefined); env.chrome.runtime.lastError = undefined; });
  };
  const reply = await refresh(env);
  assert.equal(reply.status, "unreachable");
  assert.ok(badges(env).includes("!"));
});

test("hello app-not-running: no badge, cached rules kept", async () => {
  const env = load({ native: hello({ ok: false, error: "not-running" }) });
  const reply = await refresh(env);
  assert.equal(reply.status, "app-not-running");
  assert.equal(reply.enabled, true); // cached rules (RULES.enabled) survive
  assert.equal(env.store.hostStatus, "app-not-running");
  assert.equal(badges(env).includes("!"), false);
  assert.deepEqual(env.localStore.rules, RULES);
});

test("hello ok: no '!' badge, rules updated", async () => {
  const fresh = { enabled: false, extensions: ["iso"], captureInPrivate: false };
  const env = load({ native: hello({ ok: true, rules: fresh }) });
  const reply = await refresh(env);
  assert.equal(reply.status, "ok");
  assert.equal(reply.enabled, false);
  assert.equal(env.store.hostStatus, "ok");
  assert.equal(badges(env).includes("!"), false);
  assert.equal(env.localStore.rules.extensions[0], "iso");
});

test("capture: null reply shows '!'", async () => {
  const env = load({ native: () => undefined });
  const done = env.listeners.onCreated(zipItem());
  await tick();
  env.fireTimers(8000);
  await done;
  assert.ok(badges(env).includes("!"));
});

test("capture: {ok:false,error:unavailable} shows '!' and resumes", async () => {
  const env = load({ native: (m) => (m.type === "capture" ? { ok: false, error: "unavailable" } : { ok: true, rules: RULES }) });
  await env.listeners.onCreated(zipItem());
  assert.ok(badges(env).includes("!"));
  assert.equal(env.count("resume"), 1);
});

test("capture: normal reply clears the badge", async () => {
  const env = load({ native: declinedReply });
  await env.listeners.onCreated(zipItem());
  assert.equal(badges(env).at(-1), "");
  assert.equal(env.store.hostStatus, "ok");
});

test("a rejected alarms.create is caught", async () => {
  const unhandled = [];
  const onUnhandled = (e) => unhandled.push(e);
  process.on("unhandledRejection", onUnhandled);
  try {
    load({ native: declinedReply, alarmCreateFails: true });
    await tick(20);
    assert.deepEqual(unhandled, []);
  } finally {
    process.off("unhandledRejection", onUnhandled);
  }
});

test("hello {ok:false,error:unavailable} means a broken bridge: '!' badge, unreachable", async () => {
  const env = load({ native: hello({ ok: false, error: "unavailable" }) });
  const reply = await refresh(env);
  assert.equal(reply.status, "unreachable");
  assert.ok(badges(env).includes("!"));
});

test("a not-running hello does not clear a '!' set by a capture failure", async () => {
  const env = load({ native: (m) => (m.type === "capture" ? { ok: false, error: "unavailable" } : { ok: false, error: "not-running" }) });
  await env.listeners.onCreated(zipItem());
  assert.equal(badges(env).at(-1), "!");
  await refresh(env);
  assert.equal(badges(env).at(-1), "!");
});

test("an ok hello clears the '!' badge", async () => {
  let up = false;
  const env = load({ native: (m) => (m.type === "capture" ? { ok: false, error: "unavailable" } : up ? { ok: true, rules: RULES } : { ok: false, error: "not-running" }) });
  await env.listeners.onCreated(zipItem());
  up = true;
  await refresh(env);
  assert.equal(badges(env).at(-1), "");
});

test("after a restart with empty session, the last good rules come from storage.local", async () => {
  const saved = { enabled: true, extensions: ["iso"], captureInPrivate: false };
  const env = load({ native: hello({ ok: false, error: "not-running" }), local: { rules: saved }, stored: {} });
  await tick();
  await env.listeners.onCreated(zipItem()); // a.zip: not in the saved rules
  assert.equal(env.count("pause"), 0);
  await env.listeners.onCreated(zipItem({ id: 8, url: "https://example.com/b.iso", filename: "/dl/b.iso" }));
  assert.equal(env.count("pause"), 1);
});

test("with nothing saved, DEFAULT_RULES apply", async () => {
  const env = load({ native: declinedReply, local: { rules: undefined } });
  await tick();
  await env.listeners.onCreated(zipItem());
  assert.equal(env.count("pause"), 1);
});

// The 18:52 duplicate: a tiny file finished before pause() landed. pause() "succeeded", cancel() was a no-op on the
// completed item, erase() only hid it, and Osprey downloaded it again.
test("a download that finished before the pause landed is left to the browser", async () => {
  const env = load({ native: takenReply, afterPause: { state: "complete", paused: false, bytesReceived: 100, totalBytes: 100 } });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.calls.filter((c) => c[0] === "native" && c[1] === "capture").length, 0);
  assert.equal(env.count("cancel"), 0);
  assert.equal(env.count("erase"), 0);
  assert.equal(env.count("resume"), 0);
});

test("a download still finishing (pause accepted but not paused) is not captured", async () => {
  const env = load({ native: takenReply, afterPause: { state: "in_progress", paused: false, bytesReceived: 100, totalBytes: 100 } });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.calls.filter((c) => c[0] === "native" && c[1] === "capture").length, 0);
  assert.equal(env.count("cancel"), 0);
  assert.equal(env.count("erase"), 0);
});

test("a paused download whose bytes have all arrived is resumed, not captured", async () => {
  const env = load({ native: takenReply, afterPause: { state: "in_progress", paused: true, bytesReceived: 100, totalBytes: 100 } });
  await env.listeners.onCreated(zipItem());
  assert.equal(env.calls.filter((c) => c[0] === "native" && c[1] === "capture").length, 0);
  assert.equal(env.count("resume"), 1);
  assert.equal(env.count("cancel"), 0);
});

test("an item that is already complete when onCreated fires is never paused", async () => {
  const env = load({ native: takenReply });
  await env.listeners.onCreated(zipItem({ state: "complete" }));
  assert.equal(env.count("pause"), 0);
  assert.equal(env.calls.filter((c) => c[0] === "native" && c[1] === "capture").length, 0);
});

test("a paused download with an unknown total is still captured", async () => {
  const env = load({ native: takenReply, afterPause: { state: "in_progress", paused: true, bytesReceived: 5, totalBytes: 0 } });
  await env.listeners.onCreated(zipItem());
  assert.deepEqual(env.names().filter((n) => ["pause", "cancel", "erase", "resume"].includes(n)), ["pause", "cancel", "erase"]);
});

// Task 10: the "Download video" menu item and the floating button's message.
const mediaReply = (taken) => (m) => (m.type === "media" ? { ok: true, taken } : { ok: true, rules: RULES });
const sentMedia = (env) => env.calls.find((c) => c[0] === "native" && c[1] === "media")?.[2];
const videoClick = (env, info, tab = { id: 1, incognito: false, title: "Page title" }) =>
  env.listeners.onClicked({ menuItemId: "osprey-video", pageUrl: "https://example.com/watch", ...info }, tab);

test("both menu items are created after removeAll, the video one with its own contexts", async () => {
  const env = load({ native: mediaReply(true) });
  await env.listeners.onInstalled();
  const created = env.calls.filter((c) => c[0] === "menu.create");
  assert.deepEqual(created.map((c) => c[1]), ["osprey-download", "osprey-video"]);
  assert.ok(env.names().indexOf("menu.removeAll") < env.names().indexOf("menu.create"));
  assert.equal(created[1][2].title, "Download video with Osprey");
  assert.deepEqual([...created[1][2].contexts], ["page", "video", "frame", "link"]);
  assert.deepEqual([...created[0][2].contexts], ["link", "video", "audio", "image"]);
});

test("video menu click sends media with the most specific URL: link, then frame, then page", async () => {
  const cases = [
    [{ linkUrl: "https://example.com/l", frameUrl: "https://example.com/f" }, "https://example.com/l"],
    [{ frameUrl: "https://example.com/f" }, "https://example.com/f"],
    [{}, "https://example.com/watch"],
  ];
  for (const [info, expected] of cases) {
    const env = load({ native: mediaReply(true) });
    await videoClick(env, info);
    const sent = sentMedia(env);
    assert.equal(sent.type, "media");
    assert.equal(sent.url, expected);
    assert.equal(sent.source, "menu");
    assert.equal(sent.title, "Page title");
    assert.equal(sent.private, false);
  }
});

test("video menu click on an incognito tab uses that store's cookies", async () => {
  const env = load({
    native: mediaReply(true),
    stores: [{ id: "0", tabIds: [1] }, { id: "5", tabIds: [2] }, { id: "6", tabIds: [3] }],
    cookies: (q) => [{ name: "store", value: q.storeId }],
  });
  await videoClick(env, {}, { id: 3, incognito: true, title: "T" });
  const sent = sentMedia(env);
  assert.equal(sent.cookies, "store=6");
  assert.equal(sent.private, true);
});

test("video menu click does not download in the browser when the app declines", async () => {
  const env = load({ native: mediaReply(false) });
  await videoClick(env, {});
  assert.equal(env.count("download"), 0);
});

test("video menu ignores non-http URLs and respects captureInPrivate", async () => {
  const env = load({ native: mediaReply(true) });
  await videoClick(env, { pageUrl: "chrome://extensions" });
  assert.equal(sentMedia(env), undefined);
  const priv = load({ native: mediaReply(true), local: { rules: { ...RULES, captureInPrivate: false } } });
  await videoClick(priv, {}, { id: 1, incognito: true, title: "T" });
  assert.equal(sentMedia(priv), undefined);
});

// The sender is the page that sent it (same origin as the default message URL unless the test says otherwise).
const button = (env, message, sender, async = true) =>
  new Promise((resolve) => {
    const keep = env.listeners.onMessage({ type: "media-from-button", url: "https://example.com/watch", title: "Clip", ...message },
      { url: "https://example.com/page", ...sender }, resolve);
    assert.equal(keep, async);
  });

test("media-from-button replies {taken:true} when the app takes it, with cookies and title", async () => {
  const env = load({ native: mediaReply(true), cookies: () => [{ name: "a", value: "1" }] });
  const reply = await button(env, {}, { tab: { id: 1, incognito: false } });
  assert.deepEqual(JSON.parse(JSON.stringify(reply)), { taken: true });
  const sent = sentMedia(env);
  assert.equal(sent.source, "button");
  assert.equal(sent.title, "Clip");
  assert.equal(sent.cookies, "a=1");
  assert.equal(sent.url, "https://example.com/watch");
});

test("media-from-button replies {taken:false} when declined, unreachable or refused", async () => {
  const declined = load({ native: mediaReply(false) });
  assert.deepEqual(JSON.parse(JSON.stringify(await button(declined, {}, { tab: { id: 1 } }))), { taken: false });
  const timedOut = load({ native: () => undefined });
  const pending = button(timedOut, {}, { tab: { id: 1 } });
  await tick();
  timedOut.fireTimers(8000);
  assert.deepEqual(JSON.parse(JSON.stringify(await pending)), { taken: false });
  const bad = load({ native: mediaReply(true) });
  assert.deepEqual(JSON.parse(JSON.stringify(await button(bad, { url: "javascript:1" }, { tab: { id: 1 } }, false))), { taken: false, reason: "no-link" });
  const priv = load({ native: mediaReply(true), local: { rules: { ...RULES, captureInPrivate: false } } });
  assert.deepEqual(JSON.parse(JSON.stringify(await button(priv, {}, { tab: { id: 1, incognito: true } }))), { taken: false });
  assert.equal(sentMedia(priv), undefined);
});

test("media-from-button from an incognito tab uses the incognito store", async () => {
  const env = load({
    native: mediaReply(true),
    stores: [{ id: "0", tabIds: [1] }, { id: "7", tabIds: [4] }],
    cookies: (q) => [{ name: "store", value: q.storeId }],
  });
  await button(env, {}, { tab: { id: 4, incognito: true } });
  assert.equal(sentMedia(env).cookies, "store=7");
  assert.equal(sentMedia(env).private, true);
});

test("media-from-button sends the video's own page when it is the sender's origin; cookies are read for it", async () => {
  const env = load({ native: mediaReply(true), cookies: (q) => [{ name: "for", value: q.url }] });
  await button(env, { url: "https://www.youtube.com/watch?v=abc", title: "A clip" }, { tab: { id: 1 }, url: "https://www.youtube.com/@chan" });
  assert.equal(sentMedia(env).url, "https://www.youtube.com/watch?v=abc");
  assert.equal(sentMedia(env).title, "A clip");
  assert.equal(sentMedia(env).cookies, "for=https://www.youtube.com/watch?v=abc");
  const untitled = load({ native: mediaReply(true) });
  await button(untitled, { url: "https://www.youtube.com/watch?v=abc", title: undefined }, { tab: { id: 1 }, url: "https://www.youtube.com/" });
  assert.equal(sentMedia(untitled).title, undefined);
});

test("media-from-button refuses (no-link) instead of swapping in the sender's URL", async () => {
  const refused = JSON.stringify({ taken: false, reason: "no-link" });
  const cases = [
    [{ url: "https://evil.test/x" }, "https://frame.example.com/embed"],                        // another site
    [{ url: "https://b.github.io/v" }, "https://a.github.io/page"],                              // a shared host suffix
    [{ url: "http://example.com/watch" }, "https://example.com/page"],                           // https page, http target
    [{ url: "https://m.example.com/watch" }, "https://www.example.com/page"],                    // same site, other origin
    [{ url: undefined }, "https://example.com/page"],                                            // no URL from the button
    [{}, undefined],                                                                             // no sender URL
  ];
  for (const [message, senderUrl] of cases) {
    const env = load({ native: mediaReply(true) });
    assert.equal(JSON.stringify(await button(env, message, { tab: { id: 1 }, url: senderUrl }, false)), refused, `${message.url} from ${senderUrl}`);
    assert.equal(sentMedia(env), undefined, "nothing is sent to Osprey");
  }
});

test("media-from-button needs a tab", async () => {
  const env = load({ native: mediaReply(true) });
  let answered;
  const keep = env.listeners.onMessage({ type: "media-from-button", url: "https://example.com/watch" }, { url: "https://example.com/watch" }, (r) => { answered = r; });
  await tick();
  assert.equal(keep, false);
  assert.equal(JSON.stringify(answered), JSON.stringify({ taken: false }));
  assert.equal(sentMedia(env), undefined);
});

test("video menu falls back to the next http URL when the link is not http", async () => {
  const env = load({ native: mediaReply(true) });
  await videoClick(env, { linkUrl: "javascript:void(0)", frameUrl: "about:blank" });
  assert.equal(sentMedia(env).url, "https://example.com/watch");
});

test("the context message tells a content script whether its tab is incognito", () => {
  const env = load({ native: mediaReply(true) });
  const ask = (sender) => { let r; const keep = env.listeners.onMessage({ type: "context" }, sender, (v) => { r = v; }); assert.equal(keep, false); return JSON.stringify(r); };
  assert.equal(ask({ tab: { id: 1, incognito: true } }), JSON.stringify({ incognito: true }));
  assert.equal(ask({ tab: { id: 1, incognito: false } }), JSON.stringify({ incognito: false }));
});

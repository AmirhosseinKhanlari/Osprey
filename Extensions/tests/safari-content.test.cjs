const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const dir = path.join(__dirname, "..", "safari", "Resources");
const RULES = { enabled: true, extensions: ["zip"], captureInPrivate: true };
const tick = async (n = 6) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

// Loads rules.js + content.js into a fresh vm context with a fake DOM and browser.
function load(reply, opts = {}) {
  const timers = [];
  const assigned = [];
  const listeners = [];
  const sent = [];
  class Element {}
  class FakeLink extends Element {
    constructor(href, attrs = {}) { super(); this.href = href; this.attrs = attrs; this.clicks = 0; }
    closest(sel) { return sel === "a[href]" ? this : null; }
    hasAttribute(n) { return n in this.attrs; }
    getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; }
    click() { this.clicks++; env.fire(this, { isTrusted: false }); } // a synthetic replay
    get isConnected() { return env.detached !== this; }
  }
  const env = {
    sent, FakeLink, assigned, detached: null,
    fireTimers(ms) { for (const t of timers) if (!t.done && t.ms === ms) { t.done = true; t.fn(); } },
    // Dispatches a click through the capture listener; returns the event so tests can inspect it.
    fire(target, init = {}) {
      const event = { target, button: 0, altKey: false, metaKey: false, ctrlKey: false, shiftKey: false, defaultPrevented: false, isTrusted: true,
        prevented: false, stopped: false,
        preventDefault() { this.prevented = true; this.defaultPrevented = true; },
        stopImmediatePropagation() { this.stopped = true; }, ...init };
      for (const l of listeners) l(event);
      return event;
    },
  };
  const none = { addListener() {} };
  const browser = {
    extension: { inIncognitoContext: false },
    storage: { local: { get: async () => ({ rules: RULES }) }, onChanged: none },
    runtime: {
      sendMessage: (m) => { sent.push(m); if (m.type === "capture" && opts.syncThrow) throw new Error("gone"); return Promise.resolve(m.type === "capture" ? reply(m) : undefined); },
    },
  };
  const context = vm.createContext({
    browser, Element, URL,
    setTimeout: (fn, ms) => { timers.push({ fn, ms, done: false }); return timers.length - 1; },
    clearTimeout: (id) => { if (timers[id]) timers[id].done = true; }, navigator: { userAgent: "UA" },
    location: { href: "https://example.com/page", assign: (u) => assigned.push(u) },
    document: { cookie: "a=b", addEventListener: (type, fn) => { if (type === "click") listeners.push(fn); } },
  });
  for (const f of ["rules.js", "content.js"]) vm.runInContext(fs.readFileSync(path.join(dir, f), "utf8"), context, { filename: f });
  return env;
}

const zip = (env, attrs) => new env.FakeLink("https://example.com/a.zip", attrs);
const captures = (env) => env.sent.filter((m) => m.type === "capture");

test("matching left-click is prevented and sends a capture; taken means no replay", async () => {
  const env = load(() => ({ taken: true }));
  await tick();
  const link = zip(env, { download: "a.zip" });
  const event = env.fire(link);
  await tick();
  assert.equal(event.prevented, true);
  assert.equal(event.stopped, true);
  const [msg] = captures(env);
  assert.equal(msg.url, "https://example.com/a.zip");
  assert.equal(msg.referrer, "https://example.com/page");
  assert.equal(msg.filename, "a.zip");
  assert.equal(msg.source, "auto");
  assert.equal(msg.pageUrl, "https://example.com/page");
  assert.equal(link.clicks, 0);
});

test("not taken: the click is replayed exactly once and the replay is not intercepted", async () => {
  const env = load(() => ({ taken: false }));
  await tick();
  const link = zip(env);
  env.fire(link);
  await tick();
  assert.equal(link.clicks, 1);
  assert.equal(captures(env).length, 1);
  await tick();
  assert.equal(link.clicks, 1);
});

test("a failed message also replays once", async () => {
  const env = load(() => { throw new Error("no host"); });
  await tick();
  const link = zip(env);
  env.fire(link);
  await tick();
  assert.equal(link.clicks, 1);
  assert.equal(captures(env).length, 1);
});

test("after a replay, the next real click is intercepted again", async () => {
  const env = load(() => ({ taken: false }));
  await tick();
  const link = zip(env);
  env.fire(link);
  await tick();
  const event = env.fire(link);
  assert.equal(event.prevented, true);
});

test("alt-click and modifier clicks are not intercepted", async () => {
  const env = load(() => ({ taken: true }));
  await tick();
  for (const init of [{ altKey: true }, { metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { button: 1 }]) {
    assert.equal(env.fire(zip(env), init).prevented, false, JSON.stringify(init));
  }
  assert.equal(captures(env).length, 0);
});

test("non-matching link is not intercepted", async () => {
  const env = load(() => ({ taken: true }));
  await tick();
  const event = env.fire(new env.FakeLink("https://example.com/page.html"));
  assert.equal(event.prevented, false);
  assert.equal(captures(env).length, 0);
});

test("untrusted clicks are not intercepted", async () => {
  const env = load(() => ({ taken: true }));
  await tick();
  assert.equal(env.fire(zip(env), { isTrusted: false }).prevented, false);
  assert.equal(captures(env).length, 0);
});

test("no reply within 9 s replays once; a late reply does not replay again", async () => {
  let answer;
  const env = load(() => new Promise((r) => { answer = r; }));
  await tick();
  const link = zip(env);
  env.fire(link);
  await tick();
  assert.equal(link.clicks, 0);
  env.fireTimers(9000);
  assert.equal(link.clicks, 1);
  answer({ taken: false });
  await tick();
  assert.equal(link.clicks, 1);
});

test("a timely reply cancels the timeout replay", async () => {
  const env = load(() => ({ taken: false }));
  await tick();
  const link = zip(env);
  env.fire(link);
  await tick();
  env.fireTimers(9000);
  assert.equal(link.clicks, 1);
});

test("a detached link falls back to location.assign", async () => {
  const env = load(() => ({ taken: false }));
  await tick();
  const link = zip(env);
  env.fire(link);
  env.detached = link;
  await tick();
  assert.equal(link.clicks, 0);
  assert.deepEqual(env.assigned, ["https://example.com/a.zip"]);
});

test("a synchronous sendMessage throw replays immediately, once", async () => {
  const env = load(() => ({ taken: true }), { syncThrow: true });
  await tick();
  const link = zip(env);
  env.fire(link);
  assert.equal(link.clicks, 1);
  await tick();
  env.fireTimers(9000);
  assert.equal(link.clicks, 1);
});

test("a link inside an open shadow root is found through composedPath", async () => {
  const env = load(() => ({ taken: true }));
  await tick();
  const link = zip(env);
  const inner = new env.FakeLink("https://example.com/x.txt"); // the clicked node inside the shadow tree
  inner.closest = () => link;
  const host = new env.FakeLink("https://example.com/host.html");
  host.closest = () => null;
  const event = env.fire(host, { composedPath: () => [inner, host] });
  assert.equal(event.prevented, true);
});

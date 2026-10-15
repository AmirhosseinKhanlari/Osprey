const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const shared = path.join(__dirname, "..", "shared");
const tick = async (n = 6) => { for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r)); };

class FakeNode {
  constructor(tag) { this.tag = tag; this.nodeName = tag.toUpperCase(); this.children = []; this.listeners = {}; this.style = {}; this.textContent = ""; this.removed = false; this.attrs = {}; }
  appendChild(c) { this.children.push(c); c.parent = this; return c; }
  remove() { this.removed = true; if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); }
  setAttribute(k, v) { this.attrs[k] = v; }
  dispatch(type, init = {}) {
    const event = { type, isTrusted: true, prevented: false, stopped: false,
      preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; }, stopImmediatePropagation() { this.stopped = true; }, ...init };
    for (const fn of (this.listeners[type] || []).slice()) fn(event);
    return event;
  }
  get parentElement() { return this.parent || null; }
  contains(n) { for (let x = n; x; x = x.parent) if (x === this) return true; return false; }
  attachShadow(init) { this.mode = init.mode; this.shadow = new FakeNode("#shadow"); return this.shadow; }
}

function makeVideo(width, height, left = 10, top = 10) {
  const v = new FakeNode("video");
  v.rect = { left, top, width, height, right: left + width, bottom: top + height };
  v.getBoundingClientRect = () => v.rect;
  v.isConnected = true;
  return v;
}

function setup(opts = {}) {
  const videos = [];
  const timers = [];
  const root = new FakeNode("html");
  const observers = [];
  const resizers = [];
  const document = new FakeNode("#document");
  document.documentElement = root;
  document.querySelectorAll = (sel) => (sel === "video" ? videos.filter((v) => v.isConnected) : []);
  document.createElement = (tag) => new FakeNode(tag);
  document.elementFromPoint = (x, y) => (opts.top ? opts.top(x, y) : null);
  const window = new FakeNode("#window");
  window.innerWidth = 1280;
  window.innerHeight = 800;
  window.location = { protocol: opts.protocol || "https:", href: opts.href || "https://example.com/" };
  document.title = opts.title || "";
  window.requestAnimationFrame = (fn) => { window.rafs = (window.rafs || 0) + 1; if (opts.deferRaf) { window.pending = fn; } else fn(); return 1; };
  window.setTimeout = (fn, ms) => { timers.push({ fn, ms, done: false }); return timers.length - 1; };
  window.clearTimeout = (id) => { if (timers[id]) timers[id].done = true; };
  const context = vm.createContext({
    window, document, globalThis: undefined, URL,
    ResizeObserver: opts.noResize ? undefined : class { constructor(cb) { this.cb = cb; this.watched = new Set(); this.disconnected = false; resizers.push(this); } observe(v) { this.watched.add(v); } unobserve(v) { this.watched.delete(v); } disconnect() { this.disconnected = true; } },
    MutationObserver: class { constructor(cb) { this.cb = cb; this.disconnected = false; observers.push(this); } observe() {} disconnect() { this.disconnected = true; } },
  });
  for (const f of ["rules.js", "video-button.js"]) vm.runInContext(fs.readFileSync(path.join(shared, f), "utf8"), context, { filename: f });
  const VB = vm.runInContext("typeof OspreyVideoButton === 'undefined' ? undefined : OspreyVideoButton", context);
  return {
    VB, document, window, root, videos, observers, timers, resizers,
    fire(ms) { for (const t of timers) if (!t.done && t.ms === ms) { t.done = true; t.fn(); } },
    mutate(records = []) { for (const o of observers) o.cb(records); },
    hosts: () => root.children.filter((c) => c.shadow),
    pillOf: (host) => host.shadow.children.find((c) => c.tag === "button"),
  };
}

const ON = () => ({ enabled: true, videoButton: true });

test("one pill per qualifying video, none for a small one", () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360), makeVideo(100, 60), makeVideo(800, 450, 10, 400));
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const hosts = env.hosts();
  assert.equal(hosts.length, 2);
  assert.ok(hosts.every((h) => h.mode === "closed"));
  assert.equal(env.pillOf(hosts[0]).textContent, "⬇ Download video");
});

test("the host ignores the pointer except the pill, and sits at the video's top-right", () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360, 100, 50));
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  assert.equal(host.style.pointerEvents, "none");
  assert.equal(host.style.position, "fixed");
  assert.equal(host.style.top, "58px");
  assert.equal(host.style.left, "732px");
  const css = host.shadow.children.find((c) => c.tag === "style").textContent;
  assert.match(css, /-apple-system/);
  assert.match(css, /rgba\(10,\s*108,\s*255,\s*0\.92\)/);
  assert.doesNotMatch(css, /pointer-events:\s*auto/, "the pill is clickable only while shown");
  assert.match(css, /border-radius:\s*999px/);
});

test("clicking sends once, shows progress, then the taken text for 3 s", async () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360));
  let calls = 0;
  let release;
  env.VB.attach(env.document, env.window, () => { calls++; return new Promise((r) => { release = r; }); }, ON);
  const pill = env.pillOf(env.hosts()[0]);
  const event = pill.dispatch("click");
  assert.ok(event.prevented && event.stopped);
  assert.equal(pill.textContent, "Opening Osprey…");
  pill.dispatch("click"); // a second click while busy does nothing
  assert.equal(calls, 1);
  release({ taken: true });
  await tick();
  assert.equal(pill.textContent, "Choose a quality in Osprey");
  env.fire(3000);
  assert.equal(pill.textContent, "⬇ Download video");
  pill.dispatch("click");
  assert.equal(calls, 2);
});

test("not taken, or a failed send, shows the failure text", async () => {
  for (const send of [async () => ({ taken: false }), async () => { throw new Error("x"); }, async () => undefined]) {
    const env = setup();
    env.videos.push(makeVideo(640, 360));
    env.VB.attach(env.document, env.window, send, ON);
    const pill = env.pillOf(env.hosts()[0]);
    pill.dispatch("click");
    await tick();
    assert.equal(pill.textContent, "Couldn't reach Osprey");
  }
});

test("a synchronous throw from sendMedia is treated as a failure", async () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360));
  env.VB.attach(env.document, env.window, () => { throw new Error("gone"); }, ON);
  const pill = env.pillOf(env.hosts()[0]);
  pill.dispatch("click");
  await tick();
  assert.equal(pill.textContent, "Couldn't reach Osprey");
});

test("untrusted clicks on the pill are ignored", () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360));
  let calls = 0;
  env.VB.attach(env.document, env.window, async () => { calls++; return { taken: true }; }, ON);
  env.pillOf(env.hosts()[0]).dispatch("click", { isTrusted: false });
  assert.equal(calls, 0);
});

test("removing the video removes its host", () => {
  const env = setup();
  const video = makeVideo(640, 360);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  video.isConnected = false;
  env.mutate();
  assert.ok(host.removed);
  assert.equal(env.hosts().length, 0);
});

test("a video added later gets a pill; one that shrinks is hidden", () => {
  const env = setup();
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  assert.equal(env.hosts().length, 0);
  const video = makeVideo(640, 360);
  env.videos.push(video);
  env.mutate([{ addedNodes: [video], removedNodes: [] }]);
  const [host] = env.hosts();
  assert.notEqual(host.style.display, "none");
  video.rect = { left: 0, top: 0, width: 100, height: 60, right: 100, bottom: 60 };
  env.window.dispatch("resize");
  assert.equal(host.style.display, "none");
});

test("hovering shows the pill and leaving hides it after 1.5 s", () => {
  const env = setup();
  const video = makeVideo(640, 360);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const pill = env.pillOf(env.hosts()[0]);
  const css = () => env.hosts()[0].style.opacity;
  assert.equal(css(), "0");
  video.dispatch("mouseenter");
  assert.equal(css(), "1");
  video.dispatch("mouseleave");
  assert.equal(css(), "1");
  pill.dispatch("mouseenter"); // moving onto the pill cancels the hide
  env.fire(1500);
  assert.equal(css(), "1");
  pill.dispatch("mouseleave");
  env.fire(1500);
  assert.equal(css(), "0");
});

test("repositioning is throttled to one frame", () => {
  const env = setup({ deferRaf: true });
  env.videos.push(makeVideo(640, 360));
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const before = env.window.rafs;
  for (let i = 0; i < 20; i++) { env.window.dispatch("scroll"); env.window.dispatch("resize"); env.mutate(); }
  assert.equal(env.window.rafs, before);
  env.window.pending();
  env.window.dispatch("scroll");
  assert.equal(env.window.rafs, before + 1);
});

test("never installs click listeners on the page, and respects the rules", () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360));
  let rules = { enabled: true, videoButton: false };
  const handle = env.VB.attach(env.document, env.window, async () => ({ taken: true }), () => rules);
  assert.equal(env.hosts().length, 0);
  assert.equal(env.document.listeners.click, undefined);
  assert.equal(env.window.listeners.click, undefined);
  rules = { enabled: true, videoButton: true };
  handle.refresh();
  assert.equal(env.hosts().length, 1);
});

test("detach removes hosts, observers and listeners", () => {
  const env = setup();
  env.videos.push(makeVideo(640, 360));
  const handle = env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  handle.detach();
  assert.equal(env.hosts().length, 0);
  assert.ok(env.observers.every((o) => o.disconnected));
  assert.equal((env.window.listeners.scroll || []).length, 0);
});

test("does not inject into extension or about: pages", () => {
  for (const protocol of ["chrome-extension:", "safari-web-extension:", "moz-extension:", "about:"]) {
    const env = setup({ protocol });
    env.videos.push(makeVideo(640, 360));
    const handle = env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
    assert.equal(handle, null);
    assert.equal(env.hosts().length, 0);
    assert.equal(env.observers.length, 0);
  }
});

test("the hidden pill takes no pointer; the shown one does", () => {
  const env = setup();
  const video = makeVideo(640, 360);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  const pill = env.pillOf(host);
  const css = host.shadow.children.find((c) => c.tag === "style").textContent;
  assert.match(css, /visibility:\s*inherit/);
  assert.equal(host.style.visibility, "hidden");
  assert.equal(pill.style.pointerEvents, "none");
  video.dispatch("mouseenter");
  assert.equal(host.style.visibility, "visible");
  assert.equal(pill.style.pointerEvents, "auto");
  video.dispatch("mouseleave");
  env.fire(1500);
  assert.equal(host.style.visibility, "hidden");
  assert.equal(pill.style.pointerEvents, "none");
});

test("busy pages: mutations without a video are ignored unless videos are tracked", () => {
  const env = setup({ deferRaf: true });
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  env.window.pending(); // the initial frame
  const base = env.window.rafs;
  const div = new FakeNode("div");
  div.querySelector = () => null;
  env.mutate([{ addedNodes: [div], removedNodes: [] }]);
  env.mutate([]);
  assert.equal(env.window.rafs, base);
  const video = makeVideo(640, 360);
  env.mutate([{ addedNodes: [video], removedNodes: [] }]); // video nodeName
  assert.equal(env.window.rafs, base + 1);
  env.window.pending();
  const wrapper = new FakeNode("div");
  wrapper.querySelector = (sel) => (sel === "video" ? video : null);
  env.mutate([{ addedNodes: [wrapper], removedNodes: [] }]); // subtree holding a video
  assert.equal(env.window.rafs, base + 2);
  env.window.pending();
  env.videos.push(video);
  env.window.pending = null;
});

test("tracked videos: any mutation re-checks", () => {
  const env = setup({ deferRaf: true });
  env.videos.push(makeVideo(640, 360));
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  env.window.pending();
  const base = env.window.rafs;
  env.mutate([{ addedNodes: [], removedNodes: [] }]);
  assert.equal(env.window.rafs, base + 1);
});

test("a player resize re-positions through a ResizeObserver, released on removal", () => {
  const env = setup();
  const video = makeVideo(640, 360, 100, 50);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [ro] = env.resizers;
  assert.ok(ro.watched.has(video));
  video.rect = { left: 100, top: 50, width: 900, height: 500, right: 1000, bottom: 550 };
  ro.cb([]);
  assert.equal(env.hosts()[0].style.left, "992px");
  video.isConnected = false;
  env.mutate();
  assert.ok(!ro.watched.has(video));
});

test("works without ResizeObserver", () => {
  const env = setup({ noResize: true });
  env.videos.push(makeVideo(640, 360));
  assert.ok(env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON));
  assert.equal(env.hosts().length, 1);
});

test("entering a video re-positions it", () => {
  const env = setup();
  const video = makeVideo(640, 360, 100, 50);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  video.rect = { left: 200, top: 80, width: 640, height: 360, right: 840, bottom: 440 };
  video.dispatch("mouseenter");
  assert.equal(env.hosts()[0].style.top, "88px");
});

test("after the result message the pill stays while the pointer is still over the video", async () => {
  const env = setup();
  const video = makeVideo(640, 360);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  const pill = env.pillOf(host);
  video.dispatch("mouseenter");
  pill.dispatch("click");
  await tick();
  env.fire(3000);
  env.fire(1500);
  assert.equal(host.style.visibility, "visible");
  video.dispatch("mouseleave");
  env.fire(1500);
  assert.equal(host.style.visibility, "hidden");
});

test("after the result message the pill hides when the pointer already left", async () => {
  const env = setup();
  const video = makeVideo(640, 360);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  const pill = env.pillOf(host);
  video.dispatch("mouseenter");
  pill.dispatch("click");
  video.dispatch("mouseleave");
  env.fire(1500); // busy: stays
  assert.equal(host.style.visibility, "visible");
  await tick();
  env.fire(3000);
  env.fire(1500);
  assert.equal(host.style.visibility, "hidden");
});

test("a document pointermove over a covered video shows the pill, and leaving hides it", () => {
  let env;
  env = setup({ top: () => env.videos[0] }); // an overlay sibling would be reported the same way inside the player
  env.videos.push(makeVideo(640, 360, 100, 50));
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  assert.equal(host.style.visibility, "hidden");
  env.document.dispatch("pointermove", { clientX: 300, clientY: 200 });
  assert.equal(host.style.visibility, "visible");
  env.document.dispatch("pointermove", { clientX: 1200, clientY: 700 });
  env.fire(1500);
  assert.equal(host.style.visibility, "hidden");
});

test("pointermove is throttled to a frame and does nothing when nothing is tracked", () => {
  const env = setup({ deferRaf: true });
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  env.window.pending();
  const base = env.window.rafs;
  env.document.dispatch("pointermove", { clientX: 1, clientY: 1 });
  assert.equal(env.window.rafs, base, "no tracked videos: no work scheduled");
  env.videos.push(makeVideo(640, 360));
  env.mutate([{ addedNodes: [makeVideo(1, 1)], removedNodes: [] }]);
  env.window.pending();
  const b2 = env.window.rafs;
  for (let i = 0; i < 10; i++) env.document.dispatch("pointermove", { clientX: 5, clientY: 5 });
  assert.equal(env.window.rafs, b2 + 1);
});

function parented(video, wrapperRect) {
  const player = new FakeNode("div");
  player.getBoundingClientRect = () => wrapperRect;
  const outer = new FakeNode("div");
  outer.getBoundingClientRect = () => ({ left: 0, top: 0, width: 1280, height: 4000, right: 1280, bottom: 4000 });
  outer.appendChild(player);
  player.appendChild(video);
  return { player, outer };
}

test("pointermove: a player overlay counts, a covering header or modal does not", () => {
  let top = null;
  const env = setup({ top: () => top });
  const video = makeVideo(640, 360, 100, 50);
  const { player } = parented(video, { left: 100, top: 50, width: 640, height: 360, right: 740, bottom: 410 });
  const overlay = new FakeNode("div");
  player.appendChild(overlay);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  top = overlay; // e.g. a .ytp-* layer above the video
  env.document.dispatch("pointermove", { clientX: 300, clientY: 200 });
  assert.equal(host.style.visibility, "visible");
  top = new FakeNode("header"); // a fixed header outside the player
  env.document.dispatch("pointermove", { clientX: 301, clientY: 201 });
  env.fire(1500);
  assert.equal(host.style.visibility, "hidden");
  top = host; // our own pill counts
  env.document.dispatch("pointermove", { clientX: 302, clientY: 202 });
  assert.equal(host.style.visibility, "visible");
});

test("the player container is the nearest ancestor close to the video's size", () => {
  let top = null;
  const env = setup({ top: () => top });
  const video = makeVideo(640, 360, 100, 50);
  const { outer } = parented(video, { left: 100, top: 50, width: 640, height: 360, right: 740, bottom: 410 });
  const page = new FakeNode("main"); // belongs to the huge outer ancestor, not the player
  outer.appendChild(page);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  top = page;
  env.document.dispatch("pointermove", { clientX: 300, clientY: 200 });
  assert.equal(env.hosts()[0].style.visibility, "hidden");
});

test("the hide timer does not hide while the pointer is still over the video", () => {
  const env = setup({ top: () => null });
  env.videos.push(makeVideo(640, 360, 100, 50));
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [host] = env.hosts();
  const pill = env.pillOf(host);
  const video = env.videos[0];
  env.document.elementFromPoint = () => video; // uncovered
  env.document.dispatch("pointermove", { clientX: 300, clientY: 200 });
  pill.dispatch("mouseenter");
  pill.dispatch("mouseleave"); // starts a hide timer, but the pointer is still over the video
  env.fire(1500);
  assert.equal(host.style.visibility, "visible");
});

test("every video present is watched by the ResizeObserver, so a late-eligible one gets a pill", () => {
  const env = setup();
  const video = makeVideo(100, 60);
  env.videos.push(video);
  env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON);
  const [ro] = env.resizers;
  assert.ok(ro.watched.has(video));
  assert.equal(env.hosts().length, 0);
  video.rect = { left: 10, top: 10, width: 640, height: 360, right: 650, bottom: 370 }; // a class change
  ro.cb([]);
  assert.equal(env.hosts().length, 1);
  video.isConnected = false;
  env.mutate([{ addedNodes: [], removedNodes: [video] }]);
  assert.ok(!ro.watched.has(video));
});

test("an optional gate is asked only for an eligible video; no pill until it says yes", () => {
  const env = setup();
  let asked = 0;
  let open = false;
  const gate = () => { asked++; return open; };
  env.videos.push(makeVideo(100, 60));
  const handle = env.VB.attach(env.document, env.window, async () => ({ taken: true }), ON, gate);
  assert.equal(asked, 0);                       // the small video isn't eligible: nothing to ask about
  env.videos.push(makeVideo(640, 360));
  handle.refresh();
  assert.ok(asked >= 1);
  assert.equal(env.hosts().length, 0);
  open = true;
  handle.refresh();
  assert.equal(env.hosts().length, 1);
});

// ---- Which URL the pill sends (videoTarget / videoPageUrl) ----

// A tiny DOM: el("a", { href: "/watch?v=abc" }, child, ...). Supports what the resolver reads.
class El {
  constructor(tag, attrs = {}, children = []) {
    this.nodeName = tag.toUpperCase();
    this.attrs = attrs;
    this.children = [];
    this.parentElement = null;
    this.textContent = attrs.text || "";
    for (const c of children) { c.parentElement = this; this.children.push(c); }
  }
  getAttribute(name) { return name in this.attrs && name !== "text" ? this.attrs[name] : null; }
  descendants() { return this.children.flatMap((c) => [c, ...c.descendants()]); }
  querySelectorAll(sel) {
    assert.equal(sel, "a[href]");
    return this.descendants().filter((n) => n.nodeName === "A" && n.getAttribute("href") !== null);
  }
  querySelector(sel) {
    assert.match(sel, /^#[\w-]+$/);
    return this.descendants().find((n) => n.attrs.id === sel.slice(1)) || null;
  }
}
const el = (tag, attrs, ...children) => new El(tag, attrs || {}, children);
const at = (href) => ({ href, protocol: href.split(":")[0] + ":" });
const loadVB = () => setup().VB;

test("a video inside <a href=/watch?v=…> on a channel page resolves to that watch URL", () => {
  const VB = loadVB();
  const video = el("video");
  el("ytd-rich-item-renderer", {}, el("a", { href: "/watch?v=abc", id: "thumbnail" }, el("div", {}, video)), el("a", { href: "/@chan" }));
  assert.equal(VB.videoPageUrl(video, at("https://www.youtube.com/@chan")), "https://www.youtube.com/watch?v=abc");
  assert.equal(VB.videoPageUrl(video, at("https://www.youtube.com/@chan/videos")), "https://www.youtube.com/watch?v=abc");
});

test("the YouTube inline preview (ytd-video-preview, #media-container-link) resolves to its watch URL", () => {
  const VB = loadVB();
  // The <video> deep inside the preview's anchor (more than six levels down).
  const inside = el("video");
  el("ytd-video-preview", {},
    el("div", { id: "media-container" },
      el("a", { id: "media-container-link", href: "/watch?v=prev1&pp=xyz" },
        el("div", { id: "player-container" }, el("ytd-player", {}, el("div", { id: "container" },
          el("div", { id: "movie_player" }, el("div", { class: "html5-video-container" }, inside))))))));
  assert.equal(VB.videoPageUrl(inside, at("https://www.youtube.com/")), "https://www.youtube.com/watch?v=prev1&pp=xyz");
  // The <video> beside the anchor, deeper than the nearby-container scan reaches, with other links in the preview.
  const beside = el("video");
  el("ytd-video-preview", {},
    el("a", { id: "media-container-link", href: "/watch?v=prev2" }),
    el("a", { href: "/watch?v=other" }),
    el("div", { id: "player-container" }, el("div", {}, el("div", {}, el("div", {}, el("div", {}, el("div", {}, el("div", {}, beside))))))));
  assert.equal(VB.videoPageUrl(beside, at("https://www.youtube.com/@chan")), "https://www.youtube.com/watch?v=prev2");
});

test("YouTube containers: a video-id on the way up, or the container's one watch/shorts link", () => {
  const VB = loadVB();
  const byId = el("video");
  el("ytd-rich-item-renderer", {}, el("div", { "data-video-id": "vid12345" }, el("div", {}, byId)));
  assert.equal(VB.videoPageUrl(byId, at("https://www.youtube.com/")), "https://www.youtube.com/watch?v=vid12345");
  const short = el("video");
  el("ytd-reel-item-renderer", {}, el("div", {}, el("div", {}, el("div", {}, el("div", {}, el("div", {}, el("div", {}, short)))))),
    el("a", { href: "/shorts/sh0rt" }), el("a", { href: "/shorts/sh0rt" }), el("a", { href: "/@chan" }));
  assert.equal(VB.videoPageUrl(short, at("https://www.youtube.com/@chan/shorts")), "https://www.youtube.com/shorts/sh0rt");
});

test("the main player on a /watch?v=…&list=… page gives the page URL unchanged, with the page title", () => {
  const VB = loadVB();
  const page = "https://www.youtube.com/watch?v=xyz&list=PL123&index=2";
  const video = el("video");
  el("ytd-watch-flexy", { "video-id": "xyz" }, el("div", { id: "player" }, el("div", { id: "movie_player" },
    el("a", { class: "ytp-title-link", href: "https://www.youtube.com/watch?v=xyz" }),
    el("a", { class: "ytp-ce-element", href: "/watch?v=endcard" }),
    el("div", { class: "html5-video-container" }, video))));
  assert.equal(VB.videoPageUrl(video, at(page)), page);
  assert.equal(JSON.stringify(VB.videoTarget(video, at(page), { title: "Song - YouTube" })), JSON.stringify({ url: page, title: "Song - YouTube", page: true }));
  for (const p of ["https://www.youtube.com/shorts/abc", "https://www.youtube.com/embed/abc?autoplay=1", "https://m.youtube.com/watch?v=q"]) {
    assert.equal(VB.videoPageUrl(el("video"), at(p)), p);
  }
  // A thumbnail linking to the page's own video counts as the page (keeps &list=).
  const self = el("video");
  el("a", { href: "/watch?v=xyz" }, self);
  assert.equal(VB.videoPageUrl(self, at(page)), page);
});

test("a generic site with no link gives the page URL; unrelated nearby links don't count", () => {
  const VB = loadVB();
  const lone = el("video");
  el("article", {}, el("div", {}, lone));
  assert.equal(VB.videoPageUrl(lone, at("https://example.com/post/1")), "https://example.com/post/1");
  const near = el("video");
  el("div", {}, el("div", {}, near), el("a", { href: "/about" }), el("a", { href: "#comments" }), el("a", { href: "javascript:void(0)" }));
  const target = VB.videoTarget(near, at("https://example.com/post/1"), { title: "Post" });
  assert.equal(JSON.stringify(target), JSON.stringify({ url: "https://example.com/post/1", title: "Post", page: true }));
});

test("a generic container with exactly one distinct video-like link uses it; several mean the page", () => {
  const VB = loadVB();
  const one = el("video");
  el("li", {}, el("div", {}, one), el("a", { href: "/videos/7", title: "Clip seven" }), el("a", { href: "/videos/7" }), el("a", { href: "/user/me" }));
  assert.equal(JSON.stringify(VB.videoTarget(one, at("https://clips.test/"), { title: "Home" })),
    JSON.stringify({ url: "https://clips.test/videos/7", title: "Clip seven", page: false }));
  const many = el("video");
  el("ul", {}, el("li", {}, many), el("a", { href: "/videos/1" }), el("a", { href: "/videos/2" }));
  assert.equal(VB.videoPageUrl(many, at("https://clips.test/")), "https://clips.test/");
});

test("relative and absolute hrefs; # links and links to the page itself are skipped", () => {
  const VB = loadVB();
  const rel = el("video");
  el("a", { href: "watch?v=rel" }, rel);
  assert.equal(VB.videoPageUrl(rel, at("https://www.youtube.com/@chan")), "https://www.youtube.com/watch?v=rel");
  const abs = el("video");
  el("a", { href: "https://www.youtube.com/watch?v=abs" }, abs);
  assert.equal(VB.videoPageUrl(abs, at("https://www.youtube.com/feed/subscriptions")), "https://www.youtube.com/watch?v=abs");
  const up = el("video");
  el("a", { href: "../videos/12" }, up);
  assert.equal(VB.videoPageUrl(up, at("https://example.com/a/b/page")), "https://example.com/a/videos/12");
  // Another origin would be refused by the background, so it is not used: here the page, as for no link at all.
  const other = el("video");
  el("a", { href: "https://cdn.other.test/v/9" }, other);
  assert.equal(VB.videoPageUrl(other, at("https://example.com/")), "https://example.com/");
  const insecure = el("video");
  el("a", { href: "http://www.youtube.com/watch?v=abc" }, insecure);
  assert.equal(VB.videoPageUrl(insecure, at("https://www.youtube.com/@chan")), null);
  const hash = el("video");
  el("a", { href: "#play" }, hash);
  assert.equal(VB.videoPageUrl(hash, at("https://example.com/p")), "https://example.com/p");
  const same = el("video");
  el("a", { href: "/p#t=10" }, same);
  assert.equal(VB.videoPageUrl(same, at("https://example.com/p")), "https://example.com/p");
});

test("a YouTube listing page with nothing found resolves to null: home, channel, feed, results", () => {
  const VB = loadVB();
  for (const page of ["https://www.youtube.com/", "https://www.youtube.com/@chan", "https://www.youtube.com/channel/UC1",
    "https://www.youtube.com/c/Name", "https://www.youtube.com/user/name", "https://www.youtube.com/feed/subscriptions",
    "https://www.youtube.com/results?search_query=x"]) {
    const video = el("video");
    el("ytd-browse", {}, el("div", {}, el("div", {}, video)));
    assert.equal(VB.videoPageUrl(video, at(page)), null, page);
  }
  // A wrapping link that doesn't name a video (a channel trailer linking to the channel) is not used either.
  const trailer = el("video");
  el("a", { href: "/@chan" }, trailer);
  assert.equal(VB.videoPageUrl(trailer, at("https://www.youtube.com/@chan")), null);
});

// A video element placed in a fake tree, with the box the pill needs.
function treeVideo(env) {
  const video = makeVideo(640, 360);
  video.getAttribute = () => null;
  env.videos.push(video);
  return video;
}

test("clicking on a YouTube channel page with no link shows the no-link label and sends nothing", async () => {
  const env = setup({ href: "https://www.youtube.com/@chan", title: "Chan - YouTube" });
  treeVideo(env);
  let calls = 0;
  env.VB.attach(env.document, env.window, async () => { calls++; return { taken: true }; }, ON);
  const pill = env.pillOf(env.hosts()[0]);
  pill.dispatch("click");
  await tick();
  assert.equal(calls, 0);
  assert.equal(pill.textContent, "Couldn't find this video's link");
  assert.equal(env.VB.LABEL_NO_LINK, "Couldn't find this video's link");
  env.fire(3000);
  assert.equal(pill.textContent, "⬇ Download video");
});

test("the click passes the video and its resolved target to sendMedia", async () => {
  const env = setup({ href: "https://www.youtube.com/@chan", title: "Chan - YouTube" });
  const video = treeVideo(env);
  const anchor = el("a", { href: "/watch?v=abc", title: "A clip" });
  video.parent = anchor; // FakeNode's parentElement reads .parent
  const sent = [];
  env.VB.attach(env.document, env.window, (v, target) => { sent.push([v, target]); return { taken: true }; }, ON);
  env.pillOf(env.hosts()[0]).dispatch("click");
  await tick();
  assert.equal(sent.length, 1);
  assert.equal(sent[0][0], video);
  assert.equal(JSON.stringify(sent[0][1]), JSON.stringify({ url: "https://www.youtube.com/watch?v=abc", title: "A clip", page: false }));
  // Off YouTube with no link: the page URL and document.title, as before.
  const plain = setup({ href: "https://example.com/v", title: "Page" });
  treeVideo(plain);
  const got = [];
  plain.VB.attach(plain.document, plain.window, (v, target) => { got.push(target); return { taken: true }; }, ON);
  plain.pillOf(plain.hosts()[0]).dispatch("click");
  await tick();
  assert.equal(JSON.stringify(got[0]), JSON.stringify({ url: "https://example.com/v", title: "Page", page: true }));
});

test("a link seen when the pointer entered the video is used if the preview is gone by the click", async () => {
  const env = setup({ href: "https://www.youtube.com/" });
  const video = treeVideo(env);
  video.parent = el("a", { href: "/watch?v=seen" });
  const sent = [];
  env.VB.attach(env.document, env.window, (v, target) => { sent.push(target); return { taken: true }; }, ON);
  video.dispatch("mouseenter");
  video.parent = undefined; // YouTube tore the preview down under the pill
  env.pillOf(env.hosts()[0]).dispatch("click");
  await tick();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, "https://www.youtube.com/watch?v=seen");
});

test("youtu.be links on a YouTube page become the page origin's /watch?v= (t kept)", () => {
  const VB = loadVB();
  const short = el("video");
  el("a", { href: "https://youtu.be/abc123?t=42&si=share" }, short);
  assert.equal(VB.videoPageUrl(short, at("https://www.youtube.com/@chan")), "https://www.youtube.com/watch?v=abc123&t=42");
  const plain = el("video");
  el("a", { href: "https://youtu.be/abc123" }, plain);
  assert.equal(VB.videoPageUrl(plain, at("https://www.youtube.com/")), "https://www.youtube.com/watch?v=abc123");
  // Not on YouTube: a youtu.be link is another origin and isn't used.
  const elsewhere = el("video");
  el("a", { href: "https://youtu.be/abc123" }, elsewhere);
  assert.equal(VB.videoPageUrl(elsewhere, at("https://blog.test/post")), "https://blog.test/post");
});

test("a reply of {reason:'no-link'} (refused by the background) shows the no-link label", async () => {
  const env = setup({ href: "https://example.com/v" });
  treeVideo(env);
  env.VB.attach(env.document, env.window, async () => ({ taken: false, reason: "no-link" }), ON);
  const pill = env.pillOf(env.hosts()[0]);
  pill.dispatch("click");
  await tick();
  assert.equal(pill.textContent, "Couldn't find this video's link");
});

// A video whose link (its parent <a>) can be torn down, with a controllable clock and currentSrc.
function rememberSetup() {
  const env = setup({ href: "https://www.youtube.com/" });
  let clock = 1000;
  env.window.performance = { now: () => clock };
  const video = treeVideo(env);
  video.currentSrc = "blob:https://www.youtube.com/1";
  video.parent = el("a", { href: "/watch?v=seen" });
  const sent = [];
  env.VB.attach(env.document, env.window, (v, target) => { sent.push(target); return { taken: true }; }, ON);
  const pill = env.pillOf(env.hosts()[0]);
  const clickAfterTeardown = async () => {
    video.parent = undefined;
    pill.dispatch("click");
    await tick();
    const label = pill.textContent;
    env.fire(3000);
    return label;
  };
  return { env, video, sent, pill, advance: (ms) => { clock += ms; }, clickAfterTeardown };
}

test("a remembered link expires after about 3 s: the click resolves again", async () => {
  const t = rememberSetup();
  t.video.dispatch("mouseenter");
  t.advance(2900);
  await t.clickAfterTeardown();
  assert.equal(t.sent.length, 1);
  assert.equal(t.sent[0].url, "https://www.youtube.com/watch?v=seen");
  const late = rememberSetup();
  late.video.dispatch("mouseenter");
  late.advance(3000);
  assert.equal(await late.clickAfterTeardown(), "Couldn't find this video's link");
  assert.equal(late.sent.length, 0);
});

test("a remembered link is dropped when the page URL or the video's currentSrc changes", async () => {
  const nav = rememberSetup();
  nav.video.dispatch("mouseenter");
  nav.env.window.location.href = "https://www.youtube.com/@other";
  assert.equal(await nav.clickAfterTeardown(), "Couldn't find this video's link");
  assert.equal(nav.sent.length, 0);
  const src = rememberSetup();
  src.video.dispatch("mouseenter");
  src.video.currentSrc = "blob:https://www.youtube.com/2"; // the reused preview <video> moved on to another clip
  assert.equal(await src.clickAfterTeardown(), "Couldn't find this video's link");
  assert.equal(src.sent.length, 0);
  // Also cleared by the next frame's update, before any click.
  const frame = rememberSetup();
  frame.video.dispatch("mouseenter");
  frame.video.currentSrc = "blob:https://www.youtube.com/3";
  frame.env.mutate([]);
  frame.video.currentSrc = "blob:https://www.youtube.com/1"; // back to the first clip: the old link must not return
  assert.equal(await frame.clickAfterTeardown(), "Couldn't find this video's link");
});

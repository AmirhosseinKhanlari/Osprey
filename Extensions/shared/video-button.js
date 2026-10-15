/* Shared by the Chrome and Safari content scripts (and Node tests). Classic script: no imports.
   Edit only this file; run `npm run sync` (in Extensions/) to copy it into both extensions.
   Needs rules.js (OspreyRules) loaded first. */
(function (root, factory) {
  const api = factory(root);
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.OspreyVideoButton = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function (root) {
  "use strict";

  const HIDE_DELAY_MS = 1500;
  const RESULT_MS = 3000;
  const REMEMBER_MS = 3000; // a target seen on hover is trusted this long, on the same page and the same media
  const LABEL = "⬇ Download video";
  const LABEL_BUSY = "Opening Osprey…";
  const LABEL_TAKEN = "Choose a quality in Osprey";
  const LABEL_FAILED = "Couldn't reach Osprey";
  const LABEL_NO_LINK = "Couldn't find this video's link";
  // Only ordinary web pages: never the extension's own pages, about: pages or other internal schemes.
  const PAGE_PROTOCOLS = ["http:", "https:"];

  // The host never takes the pointer; only the pill does. `all: initial` keeps page CSS out of the closed root.
  const STYLE = `
    :host { all: initial; }
    button {
      all: initial;
      visibility: inherit; pointer-events: none;
      position: absolute; top: 0; right: 0;
      box-sizing: border-box; white-space: nowrap;
      font: 13px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: #fff; background: rgba(10,108,255,0.92);
      -webkit-backdrop-filter: blur(12px) saturate(1.6); backdrop-filter: blur(12px) saturate(1.6);
      border: 1px solid rgba(255,255,255,0.25); border-radius: 999px; padding: 6px 12px;
      box-shadow: 0 2px 10px rgba(0,0,0,0.35);
      cursor: pointer; user-select: none; -webkit-user-select: none;
    }
    button:hover { background: rgba(10,108,255,1); }
  `;

  // ---- Which URL the pill downloads ----
  // A video in a thumbnail or a hover preview belongs to the link around it, not to the page: sending a YouTube home or
  // channel URL makes yt-dlp fetch every video listed there. videoTarget() resolves, in order:
  //   1. the nearest ancestor <a href> (http(s), the page's own origin, not the page itself, not a # link; on YouTube,
  //      one naming a video; youtu.be links are rewritten to the page's /watch?v= first);
  //   2. YouTube only: the thumbnail / preview container around the video (its video-id, or its one watch/shorts link);
  //   3. YouTube only: the page itself when it is a video page (/watch, /shorts/, /embed/, /live/): the main player;
  //   4. a nearby container (up to SCAN_LEVELS ancestors) holding exactly one distinct video-like link;
  //   5. YouTube only: any ancestor's video-id (e.g. the miniplayer); otherwise null: never a listing page's URL;
  //   6. elsewhere, the page URL, as before.
  // A link to the page's own video (same YouTube id) counts as the page, so the page's URL (with its &list=) is kept.
  // Result: { url, title, page } or null. `title` is document.title for the page, else the link's own title if cheap.
  const SCAN_LEVELS = 6;
  // YouTube's thumbnail and inline-preview wrappers (desktop). ytd-video-preview is the hover preview; its
  // #media-container-link is an <a href="/watch?v=…"> that may or may not contain the <video> itself.
  const YT_CONTAINERS = [
    "ytd-video-preview", "ytd-rich-item-renderer", "ytd-video-renderer", "ytd-grid-video-renderer",
    "ytd-compact-video-renderer", "ytd-reel-item-renderer", "ytd-thumbnail", "yt-lockup-view-model",
  ];
  // Path segments that usually name one video on other sites (only used for the nearby-container scan).
  const VIDEO_PATH = /\/(watch|videos?|shorts|reels?|embed|clips?|v)(\/|$)/i;
  const MEDIA_FILE = /\.(mp4|m4v|webm|mov|mkv|m3u8|mpd)$/i;

  function parseUrl(text, base) {
    const U = root.URL;
    try { return typeof U === "function" ? new U(text, base) : null; } catch (_) { return null; }
  }
  const attrOf = (el, name) => (el && typeof el.getAttribute === "function" ? el.getAttribute(name) : null);
  const tagOf = (el) => (el && el.nodeName ? String(el.nodeName).toLowerCase() : "");
  // The parent element, crossing into an open shadow root's host.
  function parentOf(el) {
    if (!el) return null;
    if (el.parentElement) return el.parentElement;
    const p = el.parentNode;
    return p && p.host && p.host !== el ? p.host : null;
  }
  const withoutHash = (u) => u.href.split("#")[0];
  const isYouTubeHost = (host) => /(^|\.)(youtube\.com|youtube-nocookie\.com)$/i.test(host || "");

  // The YouTube video id a URL names, or "".
  function youTubeId(u) {
    if (!u) return "";
    if (/^(www\.)?youtu\.be$/i.test(u.hostname)) return u.pathname.split("/")[1] || "";
    if (!isYouTubeHost(u.hostname)) return "";
    if (u.pathname === "/watch") return (u.searchParams && u.searchParams.get("v")) || "";
    const m = /^\/(shorts|embed|live|v)\/([^/?#]+)/.exec(u.pathname);
    return m ? m[2] : "";
  }

  // youtu.be/<id>[?t=…] on a YouTube page becomes <page origin>/watch?v=<id>[&t=…], so it is the page's own origin.
  function canonical(u, page) {
    if (!/^(www\.)?youtu\.be$/i.test(u.hostname) || !isYouTubeHost(page.hostname)) return u;
    const id = u.pathname.split("/")[1];
    if (!id) return u;
    const t = u.searchParams && u.searchParams.get("t");
    return parseUrl(`/watch?v=${encodeURIComponent(id)}${t ? `&t=${encodeURIComponent(t)}` : ""}`, page.origin) || u;
  }

  // A usable link from an <a>: http(s), the page's own origin (the background refuses any other), not a # link,
  // not the page itself.
  function linkOf(a, page) {
    const raw = attrOf(a, "href");
    if (!raw || /^\s*#/.test(raw)) return null;
    let u = parseUrl(raw.trim(), page.href);
    if (!u || PAGE_PROTOCOLS.indexOf(u.protocol) < 0) return null;
    u = canonical(u, page);
    if (u.origin !== page.origin) return null;
    return withoutHash(u) === withoutHash(page) ? null : u;
  }

  function videoLike(u, youTube) {
    if (youTube) return youTubeId(u) !== "";
    return youTubeId(u) !== "" || (/(^|\.)vimeo\.com$/i.test(u.hostname) && /^\/\d+/.test(u.pathname)) ||
      VIDEO_PATH.test(u.pathname) || MEDIA_FILE.test(u.pathname);
  }

  function anchorsIn(el) {
    return el && typeof el.querySelectorAll === "function" ? Array.from(el.querySelectorAll("a[href]")) : [];
  }

  // The one distinct video-like link inside `el` ({u, a}), or null when there are none or several (`many` set).
  function singleLink(el, page, youTube) {
    const seen = new Map();
    for (const a of anchorsIn(el)) {
      const u = linkOf(a, page);
      if (!u || !videoLike(u, youTube)) continue;
      const key = youTube ? `yt:${youTubeId(u)}` : withoutHash(u);
      if (!seen.has(key)) seen.set(key, { u, a });
    }
    if (seen.size === 1) return seen.values().next().value;
    return seen.size > 1 ? { many: true } : null;
  }

  // Cheap title for a link: the anchor's title, the nearby #video-title (YouTube), or the anchor's aria-label.
  function titleNear(a, scope) {
    const clean = (t) => (typeof t === "string" && t.trim() ? t.trim().replace(/\s+/g, " ").slice(0, 300) : undefined);
    let t = clean(attrOf(a, "title"));
    if (!t && scope && typeof scope.querySelector === "function") {
      const el = scope.querySelector("#video-title");
      if (el) t = clean(attrOf(el, "title")) || clean(el.textContent);
    }
    return t || clean(attrOf(a, "aria-label"));
  }

  function videoTarget(video, location, document) {
    const page = location && parseUrl(location.href);
    if (!page || PAGE_PROTOCOLS.indexOf(page.protocol) < 0) return null;
    const youTube = isYouTubeHost(page.hostname);
    const pageId = youTubeId(page);
    const pageTarget = () => ({ url: page.href, title: (document && document.title) || undefined, page: true });
    const fromLink = (u, a, scope) => {
      if (pageId && youTubeId(u) === pageId) return pageTarget(); // the page's own video: keep the page URL
      return { url: u.href, title: titleNear(a, scope || a), page: false };
    };
    const fromId = (id, scope) => {
      if (id === pageId) return pageTarget();
      const u = parseUrl(`/watch?v=${encodeURIComponent(id)}`, page.href);
      return { url: u.href, title: titleNear(null, scope), page: false };
    };

    // 1. A link wrapping the video.
    for (let el = parentOf(video); el; el = parentOf(el)) {
      if (tagOf(el) !== "a") continue;
      const u = linkOf(el, page);
      // On YouTube the link must name a video: a wrapping /@channel or /playlist link would fetch every video there.
      if (u && (!youTube || youTubeId(u))) return fromLink(u, el, youTube ? closestOf(el, YT_CONTAINERS) || el : el);
    }

    if (youTube) {
      // 2. YouTube thumbnail / hover preview: its video-id, its #media-container-link, or its one watch/shorts link.
      const box = closestOf(video, YT_CONTAINERS);
      if (box) {
        const id = videoIdUpTo(video, box);
        if (id) return fromId(id, box);
        const media = typeof box.querySelector === "function" ? box.querySelector("#media-container-link") : null;
        const mu = media && linkOf(media, page);
        if (mu && youTubeId(mu)) return fromLink(mu, media, box);
        const one = singleLink(box, page, true);
        if (one && one.u) return fromLink(one.u, one.a, box);
      }
      // 3. The main player on a video page.
      if (pageId) return pageTarget();
    }

    // 4. A nearby container with exactly one distinct video-like link.
    let el = parentOf(video);
    for (let i = 0; el && i < SCAN_LEVELS; i++, el = parentOf(el)) {
      const tag = tagOf(el);
      if (tag === "body" || tag === "html") break;
      const one = singleLink(el, page, youTube);
      if (one && one.many) break; // wider containers only hold more links
      if (one) return fromLink(one.u, one.a, el);
    }

    if (youTube) {
      // 5. Any ancestor's video-id (the miniplayer keeps the player inside a video-id host); never the listing page.
      const id = videoIdUpTo(video, null);
      return id ? fromId(id, null) : null;
    }
    // 6. Elsewhere, the page itself.
    return pageTarget();
  }

  function closestOf(el, tags) {
    for (let x = el; x; x = parentOf(x)) if (tags.indexOf(tagOf(x)) >= 0) return x;
    return null;
  }

  // The first video-id / data-video-id on the video or its ancestors, up to and including `last` (null: all of them).
  function videoIdUpTo(video, last) {
    for (let x = video; x; x = parentOf(x)) {
      const id = attrOf(x, "video-id") || attrOf(x, "data-video-id");
      if (id && /^[\w-]{6,}$/.test(id)) return id;
      if (x === last) break;
    }
    return "";
  }

  // The URL alone: what the pill would download for this video, or null (the failure label).
  function videoPageUrl(video, location) {
    const target = videoTarget(video, location, null);
    return target ? target.url : null;
  }

  // `mayShow` (optional): asked when a video first qualifies for a pill; until it returns true no pill is created.
  // Chrome uses it to ask whether the tab is private only once a video is there (call `refresh()` after it changes).
  function attach(document, window, sendMedia, getRules, mayShow) {
    const R = root.OspreyRules;
    const protocol = window.location && window.location.protocol;
    if (!R || PAGE_PROTOCOLS.indexOf(protocol) < 0) return null;
    const currentRules = () => (typeof getRules === "function" ? getRules() : R.DEFAULT_RULES);

    const observed = new Set(); // videos the ResizeObserver watches
    const entries = new Map(); // video element -> entry
    let scheduled = false;
    let detached = false;

    function clearTimer(entry, name) {
      if (entry[name] !== null) {
        window.clearTimeout(entry[name]);
        entry[name] = null;
      }
    }

    function show(entry, visible) {
      entry.hover = visible;
      entry.host.style.opacity = visible ? "1" : "0";
      entry.host.style.visibility = visible ? "visible" : "hidden";
      // `all: initial` on the button would otherwise leave an invisible clickable area over the player's controls.
      entry.pill.style.pointerEvents = visible ? "auto" : "none";
    }

    function enter(entry) {
      clearTimer(entry, "hideTimer");
      show(entry, true);
      schedule(); // the player may have moved or resized since the last frame
    }

    function leave(entry) {
      clearTimer(entry, "hideTimer");
      entry.hideTimer = window.setTimeout(() => {
        entry.hideTimer = null;
        if (!entry.busy && !entry.videoInside && !entry.pointerInside) show(entry, false);
      }, HIDE_DELAY_MS);
    }

    function finish(entry, text) {
      entry.pill.textContent = text;
      clearTimer(entry, "resetTimer");
      entry.resetTimer = window.setTimeout(() => {
        entry.resetTimer = null;
        entry.busy = false;
        entry.pill.textContent = LABEL;
        if (!entry.videoInside && !entry.pointerInside) leave(entry);
      }, RESULT_MS);
    }

    function click(entry, event) {
      // Only a real user click on the pill counts; the page must not see it either way.
      event.preventDefault();
      event.stopPropagation();
      if (!event.isTrusted || entry.busy) return;
      entry.busy = true;
      const target = targetFor(entry);
      if (!target) return finish(entry, LABEL_NO_LINK); // nothing is sent: never a whole channel or home page
      entry.pill.textContent = LABEL_BUSY;
      let pending;
      try {
        pending = Promise.resolve(sendMedia(entry.video, target));
      } catch (_) {
        pending = Promise.reject(new Error("send failed"));
      }
      // {taken:false, reason:"no-link"}: the background refused the URL (not the page's own origin); nothing was sent.
      const labelFor = (reply) => (reply && reply.taken ? LABEL_TAKEN : reply && reply.reason === "no-link" ? LABEL_NO_LINK : LABEL_FAILED);
      pending.then(labelFor, () => LABEL_FAILED).then((text) => finish(entry, text));
      return undefined;
    }

    function resolve(entry) {
      try {
        return videoTarget(entry.video, window.location, document);
      } catch (_) {
        return null;
      }
    }

    const now = () => (window.performance && typeof window.performance.now === "function" ? window.performance.now() : Date.now());
    const hrefNow = () => (window.location && window.location.href) || "";
    const srcOf = (video) => (video && typeof video.currentSrc === "string" ? video.currentSrc : "");

    // Resolved on click, and remembered when the pointer enters the video: a hover preview may already have been
    // torn down (or emptied) by the time the pill is clicked. A remembered target counts for REMEMBER_MS only, while
    // the page URL is unchanged, and is dropped as soon as the video's currentSrc changes (YouTube reuses one preview
    // <video> for every thumbnail). A link found now beats one remembered, which beats the page URL.
    function remembered(entry) {
      const r = entry.lastTarget;
      if (!r) return null;
      if (r.src !== srcOf(entry.video) || r.href !== hrefNow() || now() - r.at >= REMEMBER_MS) {
        entry.lastTarget = null;
        return null;
      }
      return r.target;
    }

    function targetFor(entry) {
      const fresh = resolve(entry);
      if (fresh && !fresh.page) return fresh;
      const old = remembered(entry);
      if (old && !old.page) return old;
      return fresh || old || null;
    }

    function remember(entry) {
      const target = resolve(entry);
      entry.lastTarget = target ? { target, at: now(), href: hrefNow(), src: srcOf(entry.video) } : null;
    }

    function create(video) {
      const host = document.createElement("div");
      host.style.cssText = "all: initial;";
      host.style.position = "fixed";
      host.style.pointerEvents = "none";
      host.style.zIndex = "2147483647";
      host.style.width = "0";
      host.style.height = "0";
      host.style.opacity = "0";
      host.style.visibility = "hidden";
      const shadow = host.attachShadow({ mode: "closed" });
      const style = document.createElement("style");
      style.textContent = STYLE;
      const pill = document.createElement("button");
      pill.textContent = LABEL;
      shadow.appendChild(style);
      shadow.appendChild(pill);
      const entry = { video, host, pill, hover: false, videoInside: false, pointerInside: false, busy: false, hideTimer: null, resetTimer: null, handlers: null, lastTarget: null };
      const onEnter = () => { entry.videoInside = true; remember(entry); enter(entry); };
      const onLeave = () => { entry.videoInside = false; leave(entry); };
      const onPillEnter = () => { entry.pointerInside = true; enter(entry); };
      const onPillLeave = () => { entry.pointerInside = false; leave(entry); };
      const onClick = (event) => click(entry, event);
      video.addEventListener("mouseenter", onEnter);
      video.addEventListener("mouseleave", onLeave);
      pill.addEventListener("mouseenter", onPillEnter);
      pill.addEventListener("mouseleave", onPillLeave);
      pill.addEventListener("click", onClick);
      entry.handlers = { onEnter, onLeave, onPillEnter, onPillLeave, onClick };
      pill.style.pointerEvents = "none";
      (document.documentElement || document.body).appendChild(host);
      return entry;
    }

    function destroy(entry) {
      clearTimer(entry, "hideTimer");
      clearTimer(entry, "resetTimer");
      const h = entry.handlers;
      entry.video.removeEventListener("mouseenter", h.onEnter);
      entry.video.removeEventListener("mouseleave", h.onLeave);
      entry.pill.removeEventListener("mouseenter", h.onPillEnter);
      entry.pill.removeEventListener("mouseleave", h.onPillLeave);
      entry.pill.removeEventListener("click", h.onClick);
      entry.host.remove();
    }

    function update() {
      if (detached) return;
      const rules = currentRules();
      const viewport = { width: window.innerWidth, height: window.innerHeight };
      const present = new Set(document.querySelectorAll("video"));
      if (resizeObserver) {
        // Watch every video, not only tracked ones: a class or style change can make a small one eligible.
        for (const video of observed) if (!present.has(video)) { resizeObserver.unobserve(video); observed.delete(video); }
        for (const video of present) if (!observed.has(video)) { resizeObserver.observe(video); observed.add(video); }
      }
      for (const [video, entry] of entries) {
        if (!present.has(video) || video.isConnected === false) {
          destroy(entry);
          entries.delete(video);
        } else if (entry.lastTarget && entry.lastTarget.src !== srcOf(video)) {
          entry.lastTarget = null; // the reused preview <video> moved on to another clip
        }
      }
      for (const video of present) {
        const rect = video.getBoundingClientRect();
        let entry = entries.get(video);
        if (!R.shouldOfferVideoButton(rect, viewport, rules)) {
          if (entry) entry.host.style.display = "none";
          continue;
        }
        if (!entry) {
          if (typeof mayShow === "function" && mayShow() !== true) continue;
          entry = create(video);
          entries.set(video, entry);
        }
        entry.host.style.display = "";
        entry.host.style.top = `${Math.max(rect.top, 0) + 8}px`;
        entry.host.style.left = `${Math.min(rect.right, viewport.width) - 8}px`;
      }
    }

    function schedule() {
      if (scheduled || detached) return;
      scheduled = true;
      window.requestAnimationFrame(() => {
        scheduled = false;
        update();
      });
    }

    function hasVideo(node) {
      if (!node) return false;
      if (node.nodeName === "VIDEO") return true;
      return typeof node.querySelector === "function" && !!node.querySelector("video");
    }

    // Busy pages mutate constantly: only a video coming or going (or tracked videos that may have moved) is worth a frame.
    function onMutations(records) {
      if (entries.size > 0) return schedule();
      for (const record of records || []) {
        for (const list of [record.addedNodes, record.removedNodes]) {
          for (const node of list ? Array.from(list) : []) if (hasVideo(node)) return schedule();
        }
      }
      return undefined;
    }

    // Players often cover the <video> with sibling layers, so it never sees mouseenter: also test the pointer
    // against the tracked rects. rAF-throttled, and nothing happens while no video is tracked.
    let point = null;
    let pointerScheduled = false;
    // The player container: the nearest ancestor whose box stays close to the video's (within 1.25x its area).
    function playerOf(video) {
      const base = video.getBoundingClientRect();
      const limit = base.width * base.height * 1.25;
      let container = video;
      for (let p = video.parentElement; p && p !== document.documentElement && p !== document.body; p = p.parentElement) {
        const r = p.getBoundingClientRect();
        if (r.width * r.height > limit) break;
        container = p;
      }
      return container;
    }

    // True when the topmost element at the point is our pill or part of the player (its own controls and overlays),
    // false when something else (a fixed header, a modal, a banner) covers the video there.
    function reachable(entry, x, y) {
      if (typeof document.elementFromPoint !== "function") return true;
      const top = document.elementFromPoint(x, y);
      if (!top) return false;
      return top === entry.host || playerOf(entry.video).contains(top);
    }

    function checkPointer() {
      pointerScheduled = false;
      if (detached || !point || entries.size === 0) return;
      for (const entry of entries.values()) {
        if (entry.host.style.display === "none") continue;
        const r = entry.video.getBoundingClientRect();
        const inRect = point.x >= r.left && point.x <= r.right && point.y >= r.top && point.y <= r.bottom;
        const inside = inRect && reachable(entry, point.x, point.y);
        if (inside === entry.videoInside) continue;
        entry.videoInside = inside;
        if (inside) { remember(entry); enter(entry); }
        else if (!entry.pointerInside) leave(entry);
      }
    }
    function onPointerMove(event) {
      if (entries.size === 0) return;
      point = { x: event.clientX, y: event.clientY };
      if (pointerScheduled) return;
      pointerScheduled = true;
      window.requestAnimationFrame(checkPointer);
    }

    const resizeObserver = typeof root.ResizeObserver === "function" ? new root.ResizeObserver(schedule) : null;
    const observer = new root.MutationObserver(onMutations);
    observer.observe(document, { childList: true, subtree: true });
    window.addEventListener("resize", schedule, { passive: true });
    window.addEventListener("scroll", schedule, { capture: true, passive: true });
    if (typeof document.addEventListener === "function") {
      document.addEventListener("loadedmetadata", schedule, true);
      document.addEventListener("pointermove", onPointerMove, { capture: true, passive: true });
    }
    schedule();

    return {
      refresh: schedule,
      detach() {
        detached = true;
        observer.disconnect();
        window.removeEventListener("resize", schedule);
        window.removeEventListener("scroll", schedule, true);
        if (typeof document.removeEventListener === "function") {
          document.removeEventListener("loadedmetadata", schedule, true);
          document.removeEventListener("pointermove", onPointerMove, true);
        }
        if (resizeObserver) resizeObserver.disconnect();
        observed.clear();
        for (const entry of entries.values()) destroy(entry);
        entries.clear();
      },
    };
  }

  return { attach, videoTarget, videoPageUrl, LABEL, LABEL_BUSY, LABEL_TAKEN, LABEL_FAILED, LABEL_NO_LINK };
});

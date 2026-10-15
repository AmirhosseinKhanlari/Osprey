// Safari has no downloads API, so link clicks are intercepted here.
(() => {
  const R = globalThis.OspreyRules;
  const api = globalThis.browser;
  let rules = R.DEFAULT_RULES;
  let replaying = false;
  const isPrivate = !!(api.extension && api.extension.inIncognitoContext);

  // The floating "Download video" pill (video-button.js). Nothing is shown until the app's rules are known.
  const VB = globalThis.OspreyVideoButton;
  let rulesKnown = false;
  let videoHandle = null;
  // `target` ({url, title}) is the video's own page, resolved by video-button.js from the link around the video, so a
  // thumbnail on a home or channel page never sends that whole page. Without one, the page itself (as before).
  // A refused link ({reason:"no-link"}) is passed on so the pill says it couldn't find the video's link.
  const replyOf = (reply) => (reply && reply.reason === "no-link" ? { taken: false, reason: "no-link" } : { taken: !!(reply && reply.taken) });
  const sendMedia = (_video, target) => {
    const t = target && target.url ? target : { url: location.href, title: document.title };
    try {
      return Promise.resolve(api.runtime.sendMessage({
        type: "media-from-button", url: t.url, title: t.title || undefined, cookies: document.cookie || undefined, isPrivate,
      })).then(replyOf, () => ({ taken: false }));
    } catch (_) {
      return Promise.resolve({ taken: false });
    }
  };
  function syncVideoButton() {
    if (!VB) return;
    const allowed = rulesKnown && rules.enabled === true && rules.videoButton !== false && (!isPrivate || rules.captureInPrivate === true);
    if (allowed && !videoHandle) videoHandle = VB.attach(document, window, sendMedia, () => rules);
    else if (!allowed && videoHandle) { videoHandle.detach(); videoHandle = null; }
    else if (videoHandle) videoHandle.refresh();
  }

  api.storage.local.get("rules").then((saved) => { if (saved && saved.rules) { rules = saved.rules; rulesKnown = true; syncVideoButton(); } }).catch(() => {});
  api.storage.onChanged.addListener((changes) => { if (changes.rules && changes.rules.newValue) { rules = changes.rules.newValue; rulesKnown = true; syncVideoButton(); } });
  api.runtime.sendMessage({ type: "rules" }).catch(() => {});

  // click() dispatches synchronously, so the flag only covers the replayed event and can never go stale.
  function replay(link) {
    if (!link.isConnected) {
      location.assign(link.href);
      return;
    }
    replaying = true;
    try {
      link.click();
    } finally {
      replaying = false;
    }
  }

  function findLink(event) {
    const path = typeof event.composedPath === "function" ? event.composedPath() : [];
    const origin = path.find((n) => n instanceof Element);
    for (const node of [origin, event.target]) {
      const link = node instanceof Element ? node.closest("a[href]") : null;
      if (link) return link;
    }
    return null;
  }

  document.addEventListener("click", (event) => {
    if (replaying) return;
    if (!event.isTrusted) return;
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
    const link = findLink(event);
    if (!link) return;
    const info = { href: link.href, hasDownloadAttribute: link.hasAttribute("download") };
    if (!R.shouldCaptureLink(info, rules, event.altKey, isPrivate)) return;
    event.preventDefault();
    event.stopImmediatePropagation();

    // Whichever of reply, failure or timeout comes first decides; later ones are ignored.
    let settled = false;
    let timer;
    const settle = (taken) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (!taken) replay(link);
    };
    timer = setTimeout(() => settle(false), R.CAPTURE_TIMEOUT_MS + 1000);
    try {
      api.runtime.sendMessage({
        type: "capture",
        url: link.href,
        referrer: location.href,
        pageUrl: location.href,
        filename: link.getAttribute("download") || undefined,
        cookies: document.cookie || undefined,
        userAgent: navigator.userAgent,
        isPrivate,
        source: "auto",
      }).then((reply) => settle(!!(reply && reply.taken)), () => settle(false));
    } catch (_) {
      settle(false);
    }
  }, true);
})();

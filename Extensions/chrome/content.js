// Holding Option (Alt) while clicking means "let Chrome download this one".
(() => {
  const report = (event) => {
    if (!event.isTrusted || event.repeat || !event.altKey) return;
    try {
      const pending = chrome.runtime.sendMessage({ type: "bypass" });
      if (pending && typeof pending.catch === "function") pending.catch(() => {});
    } catch (_) {
      // extension reloaded; ignore
    }
  };
  window.addEventListener("mousedown", report, true);
  window.addEventListener("keydown", (event) => { if (event.key === "Alt") report(event); }, true);
})();

// The floating "Download video" pill. Rules come from the cache the background keeps in storage.local.
(() => {
  const VB = globalThis.OspreyVideoButton;
  const R = globalThis.OspreyRules;
  if (!VB || !R) return;
  let rules = null; // nothing is shown until the app's rules are known
  let handle = null;

  // Is this an incognito tab? chrome.extension.inIncognitoContext answers when it is a boolean. Otherwise the background
  // is asked ({type:"context"}), but only when it matters: the rules show the pill, private windows aren't allowed, and a
  // video that qualifies is on the page. It is asked once; until it answers (and if it never does) the tab counts as private.
  const flag = (() => { try { return chrome.extension && chrome.extension.inIncognitoContext; } catch (_) { return undefined; } })();
  let isPrivate = typeof flag === "boolean" ? flag : true;
  let privacyKnown = typeof flag === "boolean";
  let asked = false;
  const rulesShowPill = () => !!rules && rules.enabled === true && rules.videoButton !== false;
  const anyWindow = () => rules.captureInPrivate === true;
  // Attach while the answer may still allow the pill; the gate below keeps it hidden until then.
  const allowed = () => rulesShowPill() && (anyWindow() || !privacyKnown || !isPrivate);
  const mayShow = () => {
    if (!rulesShowPill()) return false;
    if (anyWindow()) return true;
    if (privacyKnown) return !isPrivate;
    askContext();
    return false;
  };
  // `target` ({url, title}) is the video's own page, resolved by video-button.js from the link around the video, so a
  // thumbnail on a home or channel page never sends that whole page. Without one, the page itself (as before).
  // A refused link ({reason:"no-link"}) is passed on so the pill says it couldn't find the video's link.
  const replyOf = (reply) => (reply && reply.reason === "no-link" ? { taken: false, reason: "no-link" } : { taken: !!(reply && reply.taken) });
  const sendMedia = (_video, target) => {
    const t = target && target.url ? target : { url: location.href, title: document.title };
    try {
      return Promise.resolve(chrome.runtime.sendMessage({ type: "media-from-button", url: t.url, title: t.title || undefined }))
        .then(replyOf, () => ({ taken: false }));
    } catch (_) {
      return Promise.resolve({ taken: false }); // extension reloaded
    }
  };
  function askContext() {
    if (asked) return;
    asked = true;
    const answered = (reply) => {
      isPrivate = !(reply && reply.incognito === false);
      privacyKnown = true;
      sync();
    };
    try {
      Promise.resolve(chrome.runtime.sendMessage({ type: "context" })).then(answered, () => answered(null));
    } catch (_) {
      answered(null); // extension reloaded
    }
  }
  function sync() {
    if (allowed() && !handle) {
      handle = VB.attach(document, window, sendMedia, () => rules, mayShow);
    } else if (!allowed() && handle) {
      handle.detach();
      handle = null;
    } else if (handle) {
      handle.refresh();
    }
  }
  try {
    chrome.storage.local.get("rules").then((saved) => { if (saved && saved.rules) { rules = saved.rules; sync(); } }, () => {});
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === "local" && changes.rules && changes.rules.newValue) { rules = changes.rules.newValue; sync(); }
    });
  } catch (_) {
    // extension reloaded; ignore
  }
})();

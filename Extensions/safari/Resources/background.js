const R = globalThis.OspreyRules;
const api = globalThis.browser;
const MENU_ID = "osprey-download";
const VIDEO_MENU_ID = "osprey-video";
const RULES_TTL_MS = 60 * 1000;
let lastRefresh = 0;

function ask(message, timeoutMs) {
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), timeoutMs));
  // Safari ignores the application id argument and routes to this extension's own app.
  const reply = api.runtime.sendNativeMessage("application.id", message).catch(() => null);
  return Promise.race([reply, timeout]);
}

async function refreshRules() {
  lastRefresh = Date.now();
  const fresh = R.rulesFromHello(await ask(R.helloMessage(), R.HELLO_TIMEOUT_MS));
  if (fresh) await api.storage.local.set({ rules: fresh });
  return fresh;
}

// Every page and frame asks for rules, so answer from the cache inside the TTL.
async function rulesForContent() {
  if (Date.now() - lastRefresh < RULES_TTL_MS) {
    try {
      const saved = await api.storage.local.get("rules");
      if (saved && saved.rules) return saved.rules;
    } catch (_) { /* fall through to a refresh */ }
  }
  return refreshRules();
}

// null means the cookie API is unavailable or threw; "" means the browser really has no cookies for the URL.
async function cookiesFor(url) {
  if (!api.cookies) return null;
  try {
    return R.cookieHeader(await api.cookies.getAll({ url }));
  } catch (_) {
    return null;
  }
}

function originOf(url) {
  try { return new URL(url).origin; } catch (_) { return null; }
}

// document.cookie belongs to the page, so it may only go to the page's own origin.
function pageCookies(fields) {
  const origin = originOf(fields.url);
  return origin && origin === originOf(fields.pageUrl) ? fields.cookies || "" : "";
}

async function scopedCookies(fields) {
  // Safari's cookie API reads the normal session's store only, so a private tab never uses it:
  // it sends the private page's own document.cookie (same origin) or nothing.
  let cookies = fields.isPrivate ? null : await cookiesFor(fields.url);
  if (cookies === null) cookies = pageCookies(fields);
  return cookies;
}

async function capture(fields) {
  const cookies = await scopedCookies(fields);
  return R.wasTaken(await ask(R.captureMessage({ ...fields, cookies }), R.CAPTURE_TIMEOUT_MS));
}

// A media request launches the app like a capture does, and waits as long.
// A private request follows captureInPrivate (the app enforces it too).
async function media(fields) {
  if (!R.isHttpUrl(fields.url)) return false;
  if (fields.isPrivate) {
    let rules = null;
    try { rules = await rulesForContent(); } catch (_) { /* treated as not allowed */ }
    if (!rules || !rules.captureInPrivate) return false;
  }
  const cookies = await scopedCookies(fields);
  return R.wasTaken(await ask(R.mediaMessage({ ...fields, cookies }), R.CAPTURE_TIMEOUT_MS));
}

api.runtime.onMessage.addListener((message, sender) => {
  if (message && message.type === "capture") {
    // Safari has no per-window cookie stores; capture() keeps private tabs away from the normal session's cookies.
    const incognito = sender && sender.tab && typeof sender.tab.incognito === "boolean" ? sender.tab.incognito : !!message.isPrivate;
    return capture({ ...message, isPrivate: incognito }).then((taken) => ({ taken }));
  }
  if (message && message.type === "media-from-button") {
    const incognito = sender && sender.tab && typeof sender.tab.incognito === "boolean" ? sender.tab.incognito : !!message.isPrivate;
    if (!(sender && sender.tab)) return Promise.resolve({ taken: false }); // only content scripts in a tab send this
    // The video's own page, only when it is the sender's own origin; otherwise refuse (never the sender's URL instead).
    // Cookies are read for that URL, so they and document.cookie belong to the page's own origin by construction.
    const url = R.buttonTargetUrl(message.url, sender.url);
    if (!url) return Promise.resolve({ taken: false, reason: "no-link" });
    return media({ url, title: message.title, cookies: message.cookies, pageUrl: sender.url, isPrivate: incognito, source: "button" })
      .then((taken) => ({ taken }), () => ({ taken: false }));
  }
  if (message && message.type === "rules") {
    return rulesForContent();
  }
  return undefined;
});

async function buildMenu() {
  try { await api.contextMenus.removeAll(); } catch (_) { /* nothing to remove */ }
  try {
    await api.contextMenus.create({ id: MENU_ID, title: "Download with Osprey", contexts: ["link", "video", "audio", "image"] });
  } catch (_) { /* menu is optional */ }
  try {
    await api.contextMenus.create({ id: VIDEO_MENU_ID, title: "Download video with Osprey", contexts: ["page", "video", "frame", "link"] });
  } catch (_) { /* menu is optional */ }
}

api.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === VIDEO_MENU_ID) {
    // A menu click has no document.cookie, so only the cookie API's cookies (never in a private tab) can go along.
    const url = [info.linkUrl, info.frameUrl, info.pageUrl].find(R.isHttpUrl);
    await media({ url, title: tab && tab.title, pageUrl: info.pageUrl, isPrivate: !!(tab && tab.incognito), source: "menu" });
    return;
  }
  if (info.menuItemId !== MENU_ID) return;
  const url = info.linkUrl || info.srcUrl;
  if (!R.isHttpUrl(url)) return;
  const taken = await capture({ url, referrer: info.pageUrl, pageUrl: info.pageUrl, userAgent: navigator.userAgent,
                                isPrivate: !!(tab && tab.incognito), source: "menu" });
  // Opening the URL may display the file instead of downloading it (a Safari limitation).
  if (!taken) {
    try { await api.tabs.create({ url }); } catch (_) { /* nothing more to try */ }
  }
});

buildMenu();
refreshRules().catch(() => {});

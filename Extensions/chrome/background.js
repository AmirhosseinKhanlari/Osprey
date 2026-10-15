importScripts("rules.js");

const R = self.OspreyRules;
const RULES_TTL_MS = 60_000;
const MENU_ID = "osprey-download";
const VIDEO_MENU_ID = "osprey-video";
const ALARM_NAME = "osprey-refresh";

let rules = R.DEFAULT_RULES;
let rulesFresh = false; // true once this worker has set `rules` from the app
let rulesFetchedAt = 0;
let bypassUntil = 0;

// Downloads this extension paused and has not resolved yet (in memory), plus ones left over from a
// previous worker life that recovery has not handled yet. Mirrored to storage.session as `pending`.
const inFlight = new Set();
const stale = new Set();
let persistChain = Promise.resolve();

function persistPending() {
  persistChain = persistChain
    .then(() => chrome.storage.session.set({ pending: [...inFlight, ...stale] }))
    .catch(() => {});
  return persistChain;
}

async function readStale() {
  try {
    const saved = await chrome.storage.session.get("pending");
    for (const id of Array.isArray(saved.pending) ? saved.pending : []) {
      if (!inFlight.has(id)) stale.add(id);
    }
  } catch (_) {
    // nothing recoverable
  }
  return [...stale];
}

async function recoverPending(readDone) {
  const ids = await readDone;
  for (const id of ids) {
    try {
      const [found] = await chrome.downloads.search({ id });
      if (found && found.state === "in_progress" && found.paused && !inFlight.has(id)) {
        await chrome.downloads.resume(id);
      }
    } catch (_) {
      // gone already
    }
    stale.delete(id);
  }
  await persistPending();
}

// The service worker can be restarted at any time, so restore the last known state first.
// Never overwrite a fresher in-memory value with the stored one (the read can resolve late).
// The last good rules live in storage.local (they survive a browser restart; only the app changes them).
// bypassUntil and pending ids are short-lived and stay in storage.session.
const readRules = chrome.storage.local.get("rules").then((saved) => {
  if (saved.rules && !rulesFresh) rules = saved.rules;
}).catch(() => {});
const readBypass = chrome.storage.session.get("bypassUntil").then((saved) => {
  if (typeof saved.bypassUntil === "number") bypassUntil = Math.max(bypassUntil, saved.bypassUntil);
}).catch(() => {});
const ready = Promise.all([readRules, readBypass]);

const initialRead = readStale();
recoverPending(initialRead).catch(() => {});

function ensureAlarm() {
  try {
    Promise.resolve(chrome.alarms.get(ALARM_NAME))
      .then((existing) => (existing ? undefined : chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 })))
      .catch(() => {});
  } catch (_) {
    // alarms unavailable
  }
}
ensureAlarm();

function ask(message, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (!settled) {
        settled = true;
        resolve(value);
      }
    };
    const timer = setTimeout(() => finish(null), timeoutMs);
    try {
      chrome.runtime.sendNativeMessage(R.HOST_NAME, message, (response) => {
        clearTimeout(timer);
        finish(chrome.runtime.lastError ? null : response || null);
      });
    } catch (_) {
      clearTimeout(timer);
      finish(null);
    }
  });
}

// hostStatus: "ok" (app answered), "app-not-running" (host reachable, app quit), "unreachable" (no host, no reply or a broken bridge).
// Only "unreachable" sets the "!" badge and only "ok" clears it, so a not-running hello never hides a capture failure.
async function setStatus(status) {
  await chrome.storage.session.set({ hostStatus: status });
  if (status === "app-not-running") return;
  await chrome.action.setBadgeText({ text: status === "unreachable" ? "!" : "" });
  if (status === "unreachable") await chrome.action.setBadgeBackgroundColor({ color: "#E7A63A" });
}

const isNotRunning = (response) => !!response && response.ok === false && response.error === "not-running";

async function refreshRules(force) {
  if (!force && Date.now() - rulesFetchedAt < RULES_TTL_MS) return rules;
  rulesFetchedAt = Date.now();
  const response = await ask(R.helloMessage(), R.HELLO_TIMEOUT_MS);
  const fresh = R.rulesFromHello(response);
  if (fresh) {
    rules = fresh;
    rulesFresh = true;
    await chrome.storage.local.set({ rules });
    await setStatus("ok");
  } else if (isNotRunning(response)) {
    await setStatus("app-not-running"); // keep the cached rules
  } else {
    await setStatus("unreachable");
  }
  return rules;
}

function refreshQuietly(force) {
  return refreshRules(force).catch(() => {});
}

// Incognito cookies live in their own store. Returns undefined (default store), a store id, or null (not found).
async function cookieStoreId(incognito, tabId) {
  if (!incognito) return undefined;
  try {
    const stores = await chrome.cookies.getAllCookieStores();
    const byTab = typeof tabId === "number" ? stores.find((s) => (s.tabIds || []).includes(tabId)) : undefined;
    const found = byTab || stores.find((s) => s.id !== "0");
    return found ? found.id : null;
  } catch (_) {
    return null;
  }
}

async function cookiesFor(url, incognito, tabId) {
  try {
    const storeId = await cookieStoreId(incognito, tabId);
    if (storeId === null) return "";
    const query = storeId === undefined ? { url } : { url, storeId };
    return R.cookieHeader(await chrome.cookies.getAll(query));
  } catch (_) {
    return "";
  }
}

async function capture(fields) {
  return deliver(R.captureMessage(fields));
}

// A media request launches the app like a capture does, and waits as long.
// Private requests follow captureInPrivate (the app enforces it too).
async function media(fields) {
  if (!R.isHttpUrl(fields.url)) return false;
  await ready;
  if (fields.isPrivate && !rules.captureInPrivate) return false;
  return deliver(R.mediaMessage({
    ...fields,
    cookies: await cookiesFor(fields.url, fields.isPrivate, fields.tabId),
  }));
}

async function deliver(message) {
  const response = await ask(message, R.CAPTURE_TIMEOUT_MS);
  try {
    // Capture and media are the requests that launch the app, so "unavailable" here means it could not be started.
    await setStatus(response === null || (response.ok === false && response.error === "unavailable") ? "unreachable" : "ok");
  } catch (_) {
    // a badge or storage error must never change the decision
  }
  return R.wasTaken(response);
}

const selfStarted = new Set(); // ids of downloads this extension started itself

// Chrome accepts pause() on a download that is already finishing (every byte in, file being renamed) without
// pausing it, and cancel() is then a no-op on the finished file while erase() only hides it: Osprey would
// download it a second time. So capture only a download that is really paused with bytes still to come.
// Returns "capture", "resume" (paused, but nothing left to fetch) or "keep" (finished, finishing or gone).
async function stateAfterPause(id) {
  try {
    const [found] = await chrome.downloads.search({ id });
    if (!found || found.state !== "in_progress" || !found.paused) return "keep";
    if (found.totalBytes > 0 && found.bytesReceived >= found.totalBytes) return "resume";
    return "capture";
  } catch (_) {
    return "resume"; // can't tell: let the browser finish it
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  if (item.byExtensionId === chrome.runtime.id || selfStarted.has(item.id)) return;
  await ready;
  if (!R.shouldCaptureDownload(item, rules, Date.now(), bypassUntil)) {
    refreshQuietly(false);
    return;
  }
  if (item.state && item.state !== "in_progress") return; // finished before we saw it
  try {
    await chrome.downloads.pause(item.id);
  } catch (_) {
    return; // already finished or cancelled
  }
  const decision = await stateAfterPause(item.id);
  if (decision !== "capture") {
    if (decision === "resume") {
      try {
        await chrome.downloads.resume(item.id);
      } catch (_) {
        // the user may have acted on the download meanwhile
      }
    }
    return;
  }
  // From here the download is paused: it must be resumed unless the app took it.
  let taken = false;
  inFlight.add(item.id);
  try {
    await initialRead;
    await persistPending();
    const url = item.finalUrl || item.url;
    taken = await capture({
      url,
      referrer: item.referrer,
      filename: item.filename,
      mime: item.mime,
      size: item.fileSize > 0 ? item.fileSize : item.totalBytes,
      cookies: await cookiesFor(url, item.incognito, undefined),
      userAgent: navigator.userAgent,
      isPrivate: item.incognito,
      source: "auto",
    });
  } catch (_) {
    taken = false;
  } finally {
    try {
      if (taken) {
        await chrome.downloads.cancel(item.id);
        await chrome.downloads.erase({ id: item.id });
      } else {
        await chrome.downloads.resume(item.id);
      }
    } catch (_) {
      // the user may have acted on the download meanwhile
    }
    inFlight.delete(item.id);
    persistPending();
  }
  refreshQuietly(false);
});

chrome.runtime.onInstalled.addListener(async () => {
  try {
    await chrome.contextMenus.removeAll();
  } catch (_) {
    // nothing to remove
  }
  chrome.contextMenus.create({
    id: MENU_ID,
    title: "Download with Osprey",
    contexts: ["link", "video", "audio", "image"],
  });
  chrome.contextMenus.create({
    id: VIDEO_MENU_ID,
    title: "Download video with Osprey",
    contexts: ["page", "video", "frame", "link"],
  });
  ensureAlarm();
  refreshQuietly(true);
});

chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  recoverPending(readStale()).catch(() => {});
  refreshQuietly(true);
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) return refreshQuietly(true);
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === VIDEO_MENU_ID) {
    await media({
      url: [info.linkUrl, info.frameUrl, info.pageUrl].find(R.isHttpUrl),
      title: tab && tab.title,
      isPrivate: !!(tab && tab.incognito),
      tabId: tab && tab.id,
      source: "menu",
    });
    return;
  }
  if (info.menuItemId !== MENU_ID) return;
  const url = info.linkUrl || info.srcUrl;
  if (!R.isHttpUrl(url)) return;
  const incognito = !!(tab && tab.incognito);
  const taken = await capture({
    url,
    referrer: info.pageUrl,
    cookies: await cookiesFor(url, incognito, tab && tab.id),
    userAgent: navigator.userAgent,
    isPrivate: incognito,
    source: "menu",
  });
  if (!taken) {
    try {
      const id = await chrome.downloads.download({ url });
      if (typeof id === "number") selfStarted.add(id);
    } catch (_) {
      // blocked or invalid; nothing more to do
    }
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message && message.type === "bypass") {
    bypassUntil = Math.max(bypassUntil, Date.now() + R.BYPASS_WINDOW_MS);
    chrome.storage.session.set({ bypassUntil }).catch(() => {});
    return false;
  }
  if (message && message.type === "context") {
    // Content scripts cannot reliably tell they are in an incognito tab; the background can.
    sendResponse({ incognito: !!(_sender && _sender.tab && _sender.tab.incognito) });
    return false;
  }
  if (message && message.type === "media-from-button") {
    const tab = _sender && _sender.tab;
    if (!tab) {
      sendResponse({ taken: false }); // only content scripts in a tab send this
      return false;
    }
    // The video's own page, only when it is the sender's own origin; otherwise refuse (never the sender's URL instead).
    const url = R.buttonTargetUrl(message.url, _sender.url);
    if (!url) {
      sendResponse({ taken: false, reason: "no-link" });
      return false;
    }
    media({
      url, // cookies are read for this URL: the page's own origin by construction
      title: message.title,
      isPrivate: !!(tab && tab.incognito),
      tabId: tab && tab.id,
      source: "button",
    }).then((taken) => sendResponse({ taken }), () => sendResponse({ taken: false }));
    return true; // async reply
  }
  if (message && message.type === "refresh") {
    refreshRules(true)
      .then(async () => {
        const { hostStatus } = await chrome.storage.session.get("hostStatus");
        sendResponse({ status: hostStatus || "unreachable", enabled: !!rules.enabled });
      })
      .catch(() => sendResponse({ status: "unreachable", enabled: false }));
    return true; // async reply
  }
  return false;
});

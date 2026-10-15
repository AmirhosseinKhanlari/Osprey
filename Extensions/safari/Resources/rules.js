/* Shared by the Chrome and Safari extensions (and Node tests). Classic script: no imports.
   Edit only this file; run `npm run sync` (in Extensions/) to copy it into both extensions. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.OspreyRules = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const PROTOCOL_VERSION = 1;
  const HOST_NAME = "com.akhanlari.osprey.host";
  const BYPASS_WINDOW_MS = 2000;
  const HELLO_TIMEOUT_MS = 3000;
  // The browser download is paused meanwhile. The app side finishes within 7.5 s (a 4 s cold launch plus a 3.5 s
  // reply wait, BridgeTimeouts.swift), so a late "taken" can never arrive after this gives up and resumes.
  const CAPTURE_TIMEOUT_MS = 8000;
  const DEFAULT_RULES = Object.freeze({
    enabled: true,
    extensions: Object.freeze("3gp 7z aac ace aif apk arj asf avi bin bz2 dmg exe gz gzip img iso lzh m4a m4v mkv mov mp3 mp4 mpa mpe mpeg mpg msi msu ogg ogv pdf pkg plj pps ppt qt r0* r1* ra rar rm rmvb sea sit sitx tar tif tiff wav webm wma wmv xip xz z zip".split(" ")),
    captureInPrivate: false,
    videoButton: true,
  });
  const VIDEO_MIN_WIDTH = 240;
  const VIDEO_MIN_HEIGHT = 135;

  // Map of MIME types to the extension they imply (checked alongside the name's and the URL's).
  const MIME_EXTENSIONS = Object.freeze({
    "application/zip": "zip",
    "application/x-zip-compressed": "zip",
    "application/x-7z-compressed": "7z",
    "application/vnd.rar": "rar",
    "application/x-rar-compressed": "rar",
    "application/x-apple-diskimage": "dmg",
    "application/vnd.apple.installer+xml": "pkg",
    "application/x-msdownload": "exe",
    "application/vnd.microsoft.portable-executable": "exe",
    "application/x-msi": "msi",
    "application/pdf": "pdf",
    "application/gzip": "gz",
    "application/x-gzip": "gz",
    "application/x-bzip2": "bz2",
    "application/x-xz": "xz",
    "application/x-tar": "tar",
    "application/x-iso9660-image": "iso",
    "application/vnd.android.package-archive": "apk",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/x-matroska": "mkv",
    "video/x-msvideo": "avi",
    "video/mpeg": "mpeg",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/x-m4a": "m4a",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
    "audio/ogg": "ogg",
    "audio/aac": "aac",
  });

  function extensionForMime(mime) {
    if (!mime) return "";
    const base = String(mime).split(";")[0].trim().toLowerCase();
    return Object.prototype.hasOwnProperty.call(MIME_EXTENSIONS, base) ? MIME_EXTENSIONS[base] : "";
  }

  // Only a real URL (scheme of two or more characters) has its query and fragment stripped.
  // Single-letter schemes are Windows drive letters, so "C:\dl\b.zip" stays a path.
  function urlPathname(text) {
    try {
      const parsed = new URL(text);
      return parsed.protocol.length > 2 ? parsed.pathname : null;
    } catch (_) {
      return null;
    }
  }

  function extensionOf(nameOrUrl) {
    if (!nameOrUrl) return "";
    let path = String(nameOrUrl);
    const pathname = urlPathname(path);
    if (pathname !== null) path = pathname;
    let last = path.split(/[\\/]/).pop() || "";
    try {
      last = decodeURIComponent(last);
    } catch (_) {
      // keep the raw name
    }
    const dot = last.lastIndexOf(".");
    return dot > 0 && dot < last.length - 1 ? last.slice(dot + 1).toLowerCase() : "";
  }

  function matchesExtension(ext, patterns) {
    if (!ext || !Array.isArray(patterns)) return false;
    return patterns.some((pattern) => {
      if (typeof pattern !== "string") return false;
      const p = pattern.toLowerCase();
      if (!p) return false;
      if (p.endsWith("*")) {
        const stem = p.slice(0, -1);
        return stem !== "" && ext.startsWith(stem); // a lone "*" matches nothing
      }
      return ext === p;
    });
  }

  function isHttpUrl(url) {
    try {
      const protocol = new URL(url).protocol;
      return protocol === "http:" || protocol === "https:";
    } catch (_) {
      return false;
    }
  }

  // The download-video button's target. The content script sends the video's own page (a thumbnail's link, not the
  // listing it sits on). It is accepted only when it is http(s) and the same origin (scheme, host, port) as the frame
  // that sent it; anything else, or a missing sender URL, is null: the click is refused, never swapped for the page.
  function buttonTargetUrl(messageUrl, senderUrl) {
    if (!isHttpUrl(messageUrl) || !isHttpUrl(senderUrl)) return null;
    return new URL(messageUrl).origin === new URL(senderUrl).origin ? messageUrl : null;
  }

  function shouldCaptureDownload(item, rules, now, bypassUntil) {
    if (!rules || !rules.enabled) return false;
    const url = item.finalUrl || item.url;
    if (!isHttpUrl(url)) return false;
    if (item.incognito && !rules.captureInPrivate) return false;
    if (now < bypassUntil) return false;
    // Any listed extension is enough: a zip served as "download.php" or "page.html" still counts by its MIME type,
    // and a link to "file.7z" that redirects to a nameless storage URL still counts by the link it started from.
    return [extensionOf(item.filename), extensionOf(url), extensionOf(item.url), extensionOf(dispositionName(url)),
            extensionOf(dispositionName(item.url)), extensionForMime(item.mime)]
      .some((ext) => matchesExtension(ext, rules.extensions));
  }

  // The file name a signed storage URL (S3 and alike) asks its server to send, from its
  // `response-content-disposition` query parameter, e.g. `?response-content-disposition=attachment;filename=a.7z`.
  // `filename*=UTF-8''…` wins over `filename=`. Only the last path component is kept. "" when there is none.
  function dispositionName(url) {
    let value = null;
    try {
      for (const [key, v] of new URL(url).searchParams) {
        if (key.toLowerCase() === "response-content-disposition") value = v;
      }
    } catch (_) {
      return "";
    }
    if (!value) return "";
    let name = "";
    const extended = /filename\*\s*=\s*([^;]+)/i.exec(value);
    if (extended) {
      const raw = extended[1].trim().replace(/^"|"$/g, "");
      const quote = raw.indexOf("''");
      try {
        name = decodeURIComponent(quote >= 0 ? raw.slice(quote + 2) : raw);
      } catch (_) {
        name = "";
      }
    }
    if (!name) {
      const plain = /filename\s*=\s*("([^"]*)"|[^;]+)/i.exec(value);
      if (plain) name = (plain[2] !== undefined ? plain[2] : plain[1]).trim();
    }
    return (name.split(/[\\/]/).pop() || "").trim();
  }

  // The name to hand Osprey with a download: Chrome's own once it knows it, else one a storage URL names in its query,
  // else the last part of the link the download started from when that has an extension (it may redirect to a URL
  // without a name), else "".
  function suggestedFilename(item) {
    if (item.filename) return item.filename;
    const named = dispositionName(item.finalUrl || item.url) || dispositionName(item.url);
    if (named) return named;
    if (!extensionOf(item.url)) return "";
    const pathname = urlPathname(String(item.url));
    let last = (pathname === null ? String(item.url) : pathname).split("/").pop() || "";
    try {
      last = decodeURIComponent(last);
    } catch (_) {
      // keep the raw name
    }
    return last;
  }

  function shouldCaptureLink(link, rules, altKey, isPrivate) {
    if (!rules || !rules.enabled || altKey) return false;
    if (!isHttpUrl(link.href)) return false;
    if (isPrivate && !rules.captureInPrivate) return false;
    if (link.hasDownloadAttribute) return true;
    return [extensionOf(link.href), extensionOf(dispositionName(link.href))].some((ext) => matchesExtension(ext, rules.extensions));
  }

  function captureMessage(fields) {
    return {
      v: PROTOCOL_VERSION,
      type: "capture",
      url: fields.url,
      referrer: fields.referrer || undefined,
      filename: fields.filename || undefined,
      mime: fields.mime || undefined,
      size: fields.size > 0 ? fields.size : undefined,
      cookies: fields.cookies || undefined,
      userAgent: fields.userAgent || undefined,
      private: !!fields.isPrivate,
      source: fields.source === "menu" ? "menu" : "auto",
    };
  }

  function helloMessage() {
    return { v: PROTOCOL_VERSION, type: "hello" };
  }

  function wasTaken(response) {
    return !!(response && response.ok === true && response.taken === true);
  }

  function cookieHeader(cookies) {
    return (cookies || []).map((c) => `${c.name}=${c.value}`).join("; ");
  }

  // Returns well-formed rules or null. Bad fields fall back to defaults; a non-boolean `enabled` is refused.
  function rulesFromHello(response) {
    if (!response || response.ok !== true) return null;
    const rules = response.rules;
    if (!rules || typeof rules !== "object" || typeof rules.enabled !== "boolean") return null;
    const extensions = Array.isArray(rules.extensions)
      ? rules.extensions.filter((ext) => typeof ext === "string")
      : DEFAULT_RULES.extensions.slice();
    return {
      enabled: rules.enabled, extensions, captureInPrivate: rules.captureInPrivate === true,
      videoButton: rules.videoButton !== false,
    };
  }

  // rect: {width, height, top, left, bottom, right} in CSS px; viewport: {width, height}.
  function shouldOfferVideoButton(rect, viewport, rules) {
    if (!rules || !rules.enabled || rules.videoButton === false) return false;
    if (!rect || !viewport) return false;
    if (!(rect.width >= VIDEO_MIN_WIDTH && rect.height >= VIDEO_MIN_HEIGHT)) return false;
    return rect.right > 0 && rect.bottom > 0 && rect.left < viewport.width && rect.top < viewport.height;
  }

  function mediaMessage(fields) {
    return {
      v: PROTOCOL_VERSION,
      type: "media",
      url: fields.url,
      title: fields.title || undefined,
      cookies: fields.cookies || undefined,
      private: !!fields.isPrivate,
      source: fields.source === "menu" ? "menu" : "button",
    };
  }

  return {
    PROTOCOL_VERSION, HOST_NAME, BYPASS_WINDOW_MS, HELLO_TIMEOUT_MS, CAPTURE_TIMEOUT_MS, DEFAULT_RULES, VIDEO_MIN_WIDTH, VIDEO_MIN_HEIGHT,
    MIME_EXTENSIONS, extensionOf, extensionForMime, matchesExtension, isHttpUrl, shouldCaptureDownload, suggestedFilename,
    dispositionName, shouldCaptureLink,
    captureMessage, mediaMessage, shouldOfferVideoButton, helloMessage, wasTaken, cookieHeader, rulesFromHello,
    buttonTargetUrl,
  };
});

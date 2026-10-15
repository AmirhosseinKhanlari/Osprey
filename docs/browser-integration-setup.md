# Browser integration: setup and checks

Osprey takes over downloads from Chrome-family browsers (Chrome, Chromium, Edge, Brave) and Safari. This page covers building and installing it, and the manual end-to-end checks.

> **Safari support is experimental.** Its manual end-to-end checks (below) haven't been run yet, so treat it as not verified.

## Build and install
The Desktop folder is synced to iCloud, and signing fails for build output stored inside it. Build into a folder outside the Desktop instead.

1. Generate the Xcode project and build it. Install a **Release** build: Debug builds keep development escape hatches (`OSPREY_BRIDGE_SOCKET`, `OSPREY_BRIDGE_INSECURE`) that a Release build compiles out.
   ```
   xcodegen generate
   xcodebuild -project Osprey.xcodeproj -scheme Osprey -configuration Release \
     -derivedDataPath /tmp/osprey-dd -allowProvisioningUpdates build
   ```
2. Copy the app to `/Applications` and launch it once:
   ```
   ditto /tmp/osprey-dd/Build/Products/Release/Osprey.app /Applications/Osprey.app
   open /Applications/Osprey.app
   ```
   On every launch, the app writes the Chrome helper manifest to `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.akhanlari.osprey.host.json`. It also writes it for Chromium, Edge and Brave when they are installed. The manifest's `path` must point at `/Applications/Osprey.app/Contents/MacOS/osprey-host`. If you open a copy of the app from somewhere else, the manifest points at that copy instead, so launch the `/Applications` copy last.

### Upgrading from the app's earlier name
The first time Osprey runs, it imports what the earlier build kept: its settings (media folders, quality, audio language, subtitle choice, browser-integration rules, window layout) and its managed yt-dlp and ffmpeg. Custom folders keep their paths. The old data is copied, not moved, and once the import has finished it never runs again. It also deletes the earlier build's Chrome helper manifests, which pointed at the old app, and, on the first launch while the old app isn't running, the temporary files the old app left after a crash. Then:
- In `chrome://extensions`, click **Reload** on the extension. The folder (`Extensions/chrome`) and the extension ID are unchanged.
- In **Safari → Settings → Extensions**, tick **Osprey** again: Safari sees the renamed extension as a new one, so Osprey shows its Safari setup prompt again.
- Delete the old app, `/Applications/Slipstream.app` (move it to the Trash). If **Slipstream** is still listed in **Safari → Settings → Extensions**, untick it so that only **Osprey** is on.

## Chrome
1. Open `chrome://extensions` and turn on **Developer mode**. Click **Load unpacked**, then choose the `Extensions/chrome` folder.
2. Check that the extension ID is `hdaelhdfolkmnghifnpopgadkndofanj`. If it isn't, the manifest's `key` was changed.
3. Click the toolbar icon. The popup shows one of three states:
   - **Connected.** Matching downloads go to Osprey.
   - **Osprey isn't running.** It starts automatically on the next matching download. A rules check never launches the app.
   - **Can't reach Osprey.** The helper is missing or broken. The toolbar icon also shows a "!" badge. Open Osprey, or use **Settings → Browser integration → Repair Chrome helper**.

## Safari (experimental)
1. Locally built extensions are signed for development, so Safari has to be allowed to load them. Turn on **Safari → Settings → Advanced → Show features for web developers**, then choose **Develop → Allow Unsigned Extensions**. Safari turns this setting off again when it quits.
2. Launch Osprey and accept the **Turn on Osprey in Safari** prompt, or open **Safari → Settings → Extensions** yourself.
3. Tick **Osprey**, then choose **Always Allow on Every Website**.

## How it behaves
- **What gets taken over:** downloads whose file type is in the list under **Settings → Browser integration**. The defaults cover archives, disk images, installers, video, audio and PDF. The right-click item **Download with Osprey** works on any link.
- **Bypass:** hold **⌥ Option** while clicking a link to let the browser download it instead.
- **Fallback:** if Osprey can't take a download, the browser keeps it. A Chrome download stays paused while it waits, for at most 8 s.
- **Progress window:** each captured download opens a small progress window in the top-right corner of the screen (up to 5 at a time; more wait their turn). It doesn't bring Osprey forward. Turn it off under **Settings → Browser integration** to get a notification instead.
- **Private windows:** downloads from private windows stay with the browser unless **Also in private windows** is on. Notifications for private captures never show the file name, and Safari never sends normal-session cookies for a private tab.
- **Safari limitation:** Safari has no downloads API, so only link clicks are intercepted. Downloads started by scripts, by redirects, or by a server-chosen file name on a link without a matching extension stay in Safari. Use the right-click item for those.

## Video downloads
Osprey can save videos from web pages (YouTube, Vimeo and other sites yt-dlp supports), not only direct file links. Chrome and Safari both send pages to it; Safari is still experimental.

### Ways to start
- **Add URL:** paste a page link. Osprey notices it is a web page and offers **Download video instead**, which opens the picker.
- **Right-click:** **Download video with Osprey** on a page, a link, a video or a frame. Osprey gets the most specific address: the link, then the frame, then the page.
- **Video button:** a floating **Download video** button appears over videos. Clicking it opens the picker in Osprey. Turn it off with **Show download button over videos** in **Settings → Media**.

### The picker
- **Quality:** each quality lists an estimated size. A "~" means the size is approximate.
- **Compatible (MP4/H.264):** on by default. It prefers H.264 video and AAC audio in MP4, which QuickTime and Photos play. Turn it off for the best quality, often VP9 or AV1. Those formats are marked **Won't play in QuickTime**; they play in apps like IINA or VLC.
- **Audio only:** M4A (the original AAC, not converted) or MP3 (converted, which needs ffmpeg).
- **Subtitles:** choose a language, and optionally **Include auto-generated**.
- **Save to:** the folder for this download. The defaults are set under **Settings → Media**.

### Playlists
- The picker shows a checklist of the playlist's videos (**Select all** / **Select none**).
- One quality choice applies to every selected entry.
- The downloads go into a folder named after the playlist.
- While entries are being looked up, a banner reads "Adding N of M" with a **Stop** button. Entries already added stay.

### Tools
- Osprey installs its own yt-dlp, verifies it against a checksum, and checks for a new version once a day. It never modifies a Homebrew copy.
- If its own download fails, it uses Homebrew's yt-dlp instead and tries its own again after 10 min.
- ffmpeg joins video and audio and converts to MP3. Osprey uses Homebrew's copy if present and otherwise downloads a verified build when needed (**Install**). Without ffmpeg the picker still lists every format, marks the ones that need it with **Needs ffmpeg — Install**, and they can be downloaded once ffmpeg is there.
- **Settings → Media → Tools** shows each tool's version, source (Managed or Homebrew) and last check, with **Update now** and **Install**.

### Privacy
- Every **Download video** button click and right-click request sends the browser's cookies for the page's site (and only that site), so videos that need you to be signed in work. Add URL sends none.
- Osprey writes them into a private temporary file (readable only by you) that yt-dlp reads and that is deleted right after the lookup or download, and when Osprey quits. They are never saved or logged.
- In a playlist, an entry on another site gets no cookies.
- The private-window rules above apply: a private-window video isn't taken over unless **Also in private windows** is on, and Safari never sends normal-session cookies for a private tab.

### Protected (DRM) videos
Encrypted streams can't be downloaded. Osprey says "This video is protected (DRM) and can't be downloaded" rather than failing silently. If only some qualities are protected, the rest are listed and the picker notes that some aren't shown.

### Troubleshooting
- **"Osprey can't find a video on this page."** The page has no video yt-dlp can read. Open the video's own page and try again.
- **"This video needs you to be signed in."** Sign in in your browser and use the **Download video** button there, so the browser's cookies can be used.
- **A site stopped working.** Open **Settings → Media** and click **Update now** for yt-dlp.

## Manual end-to-end checklist
Record each item as pass, or as fail with what happened.

**Chrome**
- [ ] Clicking a `.zip` link starts the download in Osprey, and its progress window appears (top right) without bringing Osprey forward. Chrome doesn't keep the item.
- [ ] ⌥ Option-clicking the same link makes Chrome download it itself.
- [ ] Right-clicking any link → **Download with Osprey** captures it, even for a file type that isn't in the list.
- [ ] With Osprey quit, clicking a `.zip` relaunches Osprey in the background and captures the download. The popup shows "Osprey isn't running" beforehand, with no "!" badge.
- [ ] With **Take over downloads** turned off in Settings, Chrome downloads normally, and the popup says the integration is off.
- [ ] In an incognito window, Chrome downloads normally (with the default setting).

**Safari** (not yet run: Safari is experimental until these pass)
- [ ] Clicking a `.dmg` link captures it in Osprey.
- [ ] Right-click → **Download with Osprey** works.
- [ ] ⌥ Option-clicking makes Safari download it.
- [ ] With Osprey quit and its app bundle temporarily renamed, Safari downloads normally within about a second.

**Video downloads**
- [ ] Use Big Buck Bunny (`https://www.youtube.com/watch?v=aqz-KE-bpKQ`, CC BY) as the default test video. Through **Add URL** → **Download video instead**, at 1080p with **Compatible (MP4/H.264)** on, the merged MP4 plays in QuickTime.
- [ ] The same video through the Chrome **Download video** button.
- [ ] Right-click a YouTube link → **Download video with Osprey**.
- [ ] A 3-video playlist at **Audio · M4A** gives three `.m4a` files in a folder named after the playlist.
- [ ] An HLS site (for example a Vimeo video) downloads through the fragment path.
- [ ] Pause and resume a two-part YouTube download.
- [ ] A DRM-protected page shows "protected" and downloads nothing.
- [ ] **Settings → Media** shows the yt-dlp version, and **Update now** works.

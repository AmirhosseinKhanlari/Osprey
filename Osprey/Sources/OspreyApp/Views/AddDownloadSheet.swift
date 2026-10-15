import OspreyEngine
import OspreyLibrary
import OspreyMedia
import SwiftUI
import UniformTypeIdentifiers

struct AddDownloadSheet: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(MediaCoordinator.self) private var media
    @Environment(\.dismiss) private var dismiss
    @AppStorage("maxConnections") private var defaultConnections = 8
    @State private var address = ""
    @State private var category: Category = .other
    @State private var connections = 8
    @State private var startNow = true
    /// "Download later"'s queue; nil until the user picks one (then Later, or the first queue after Main).
    @State private var laterQueue: UUID?
    @State private var probe: ProbeResult?
    @State private var probeError: String?
    /// Once the user picks a category, the probe stops suggesting one.
    @State private var userPickedCategory = false
    @FocusState private var addressFocused: Bool

    private let steps = [1, 2, 4, 8, 12, 16, 24, 32]
    private var url: URL? { Self.webURL(from: address) }

    /// The link is a web page (the server answered HTML) or on a known video or audio site: offer the picker.
    private var looksLikeWebPage: Bool {
        guard let url else { return false }
        if let type = probe?.contentType?.lowercased(), type.hasPrefix("text/html") { return true }
        return MediaURL.siteKind(url) != .unknown
    }

    /// An http(s) URL with a host, ignoring surrounding whitespace and newlines; nil otherwise.
    static func webURL(from string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New download").font(.system(size: 19, weight: .bold)).tracking(-0.2)
                Text("Paste a link. Osprey checks the file before it starts.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            addressField
            DetectedFileCard(category: category, host: url?.host(), probe: probe, probeError: probeError,
                             hasURL: url != nil)
            if looksLikeWebPage, let url {
                WebPageBanner(kind: MediaURL.siteKind(url)) { media.open(url: url) }
            }
            FormGroup {
                FormRow(title: "Save to") {
                    ChipLabel(text: Format.crumbs(manager.rootFolder.appending(path: category.rawValue)),
                              symbol: "folder", showsChevron: false)
                        .help(Format.path(manager.rootFolder.appending(path: category.rawValue)))
                }
                FormRow(title: "Category") {
                    Menu {
                        ForEach(Category.allCases) { option in
                            Button(option.rawValue) {
                                category = option
                                userPickedCategory = true
                            }
                        }
                    } label: {
                        ChipLabel(text: category.rawValue)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Category, \(category.rawValue)")
                }
                FormRow(title: "Connections") {
                    ChipStepper(label: "connections", values: steps, value: $connections)
                }
                FormRow(title: "When") {
                    // "Later" waits in a queue until that queue starts (by hand or on its schedule).
                    ChipSegments(options: [(true, "Start now"), (false, "Download later")], selection: $startNow)
                }
                FormRow(title: "Queue", showsDivider: false) { queuePicker }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 36, fontSize: 13))
                    .keyboardShortcut(.cancelAction)
                Button("Download") { add() }
                    .buttonStyle(.capsule(.primary, height: 36, fontSize: 13))
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
        .onAppear {
            connections = defaultConnections
            if let string = NSPasteboard.general.string(forType: .string), let url = Self.webURL(from: string) {
                address = url.absoluteString
            }
            addressFocused = true
        }
        .task(id: address) { await runProbe() }
    }

    /// Always shown, so the sheet keeps its size: "Start now" goes to Main (shown dimmed), "Download later" to the
    /// queue picked here.
    private var queuePicker: some View {
        let chosen = startNow ? manager.queue(Queue.mainID) : manager.queue(laterQueue ?? manager.defaultLaterQueueID)
        let name = chosen?.name ?? "Main"
        return Menu {
            // Checkmark on the current choice.
            Picker("Queue", selection: Binding(get: { chosen?.id ?? Queue.mainID }, set: { laterQueue = $0 })) {
                ForEach(manager.queues) { queue in
                    Text(queue.name).tag(queue.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ChipLabel(text: name, maxTextWidth: 220)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(startNow)
        .opacity(startNow ? 0.5 : 1)
        .help(startNow ? "Start now downloads in Main. Choose Download later to pick a queue." : "The queue it waits in")
        .accessibilityLabel("Queue, \(name)")
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                TextField("Address", text: $address, prompt: Text("https://…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($addressFocused)
                    .onSubmit { if url != nil { add() } }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(addressFocused ? Theme.accent.opacity(0.55) : Theme.stroke)
            }
            .background {
                if addressFocused {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Theme.accent.opacity(0.14))
                        .padding(-4)
                }
            }
            .animation(.easeOut(duration: 0.15), value: addressFocused)
        }
    }

    private func runProbe() async {
        probe = nil
        probeError = nil
        guard let url else { return }
        try? await Task.sleep(for: .milliseconds(350))   // debounce typing
        guard !Task.isCancelled else { return }
        do {
            let result = try await Prober.probe(URLRequest(url: url), session: .shared)
            guard !Task.isCancelled else { return }       // the address changed while probing
            probe = result
            if !userPickedCategory { category = Category.infer(fromFileName: result.suggestedFilename) }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            probeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add() {
        guard let url else { return }
        manager.add(url, connections: connections, category: category, startNow: startNow,
                    queue: startNow ? nil : (laterQueue ?? manager.defaultLaterQueueID))
        dismiss()
    }
}

/// "This looks like a web page — Download video/audio/media instead": hands the link to the picker. "video" and
/// "audio" only for known sites; any other page says "media".
private struct WebPageBanner: View {
    let kind: MediaKind
    let openPicker: () -> Void

    private var noun: String {
        switch kind {
        case .video: "video"
        case .audio: "audio"
        case .unknown: "media"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .audio ? "music.note" : "play.rectangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("This looks like a web page").font(.system(size: 13, weight: .semibold))
                Text(kind == .unknown ? "Osprey can download the video or audio on it instead."
                                      : "Osprey can download the \(noun) on it instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Download \(noun) instead", action: openPicker)
                .buttonStyle(.capsule(.primary, height: 30, fontSize: 12.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.18)))
    }
}

/// What the probe found: name, size, kind and host, and whether the server can resume.
private struct DetectedFileCard: View {
    let category: Category
    let host: String?
    let probe: ProbeResult?
    let probeError: String?
    let hasURL: Bool

    var body: some View {
        HStack(spacing: 14) {
            CategoryTile(category: category, size: 46, cornerRadius: 12, symbolSize: 20)
            VStack(alignment: .leading, spacing: 3) {
                if let probe {
                    Text(probe.suggestedFilename).font(.system(size: 14, weight: .bold)).lineLimit(1).truncationMode(.middle)
                    Text(details(probe)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else if let probeError {
                    Text("Couldn’t check this link").font(.system(size: 14, weight: .bold))
                    Text(probeError).font(.system(size: 12)).foregroundStyle(Theme.error).lineLimit(2)
                } else if hasURL {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking the file…").font(.system(size: 13, weight: .semibold))
                    }
                    Text(host ?? "").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("No link yet").font(.system(size: 14, weight: .bold))
                    Text("Paste an http or https address to check it.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let probe { badge(resumable: probe.acceptsRanges) }
        }
        .padding(14)
        .background(Theme.tile.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }

    /// "412 MB · Disk image · download.blender.org"
    private func details(_ probe: ProbeResult) -> String {
        [probe.totalSize.map(Format.bytes) ?? "Unknown size", kind(probe), probe.finalURL.host() ?? host]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func kind(_ probe: ProbeResult) -> String? {
        let ext = (probe.suggestedFilename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let name = type.localizedDescription,
           !type.isDynamic {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        let mime = probe.contentType?.split(separator: ";").first.map(String.init)
        guard let mime, mime != "application/octet-stream", let type = UTType(mimeType: mime),
              let name = type.localizedDescription else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func badge(resumable: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: resumable ? "checkmark" : "arrow.right")
                .font(.system(size: 10, weight: .heavy))
            Text(resumable ? "Resumable" : "Single connection")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(resumable ? Theme.pill(.completed).foreground : Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(resumable ? Theme.pill(.completed).background : Theme.chip, in: Capsule())
        .help(resumable ? "The server serves byte ranges: Osprey can split and resume this download."
                        : "The server doesn’t serve byte ranges: one connection, and a restart begins again.")
    }
}

import Foundation

/// Checks on page addresses that come from outside (the browser, the user, a site's playlist JSON).
public enum MediaURL {
    /// An absolute http(s) address with a host: the only kind handed to yt-dlp or to URLSession.
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return true
    }

    // MARK: Cookie scope

    /// A playlist page's cookies (sent by the browser for that page's site) may go with an entry only when the entry is
    /// on the same host or shares its registrable domain (`music.youtube.com` and `www.youtube.com`). A simple rule:
    /// the last two labels, or three under a two-letter country code with a generic second level (`bbc.co.uk`).
    public static func mayShareCookies(from page: URL, with entry: URL) -> Bool {
        guard isWebURL(page), isWebURL(entry),
              let a = page.host(percentEncoded: false)?.lowercased(), let b = entry.host(percentEncoded: false)?.lowercased()
        else { return false }
        if a == b { return true }
        guard let siteA = registrableDomain(a), let siteB = registrableDomain(b) else { return false }
        return siteA == siteB
    }

    /// `header` when the entry may receive the page's cookies, else nil.
    public static func cookieHeader(_ header: String?, from page: URL, for entry: URL) -> String? {
        guard let header, mayShareCookies(from: page, with: entry) else { return nil }
        return header
    }

    private static let genericSecondLevels: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "gob", "mil"]

    /// Nil for an IP address or a single-label host (those must match exactly).
    static func registrableDomain(_ host: String) -> String? {
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        if trimmed.contains(":") { return nil }                                   // IPv6
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }        // IPv4
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        if labels.count >= 3, tld.count == 2, genericSecondLevels.contains(second) {
            return labels.suffix(3).joined(separator: ".")
        }
        if labels.count == 2, tld.count == 2, genericSecondLevels.contains(second) { return nil }   // "co.uk" itself
        return labels.suffix(2).joined(separator: ".")
    }

    // MARK: Playlist or single video

    /// True when the address names one video inside a list (`watch?v=X&list=Y`, `youtu.be/X?list=Y`,
    /// `/shorts/X?list=Y`): that video is looked up alone (`--no-playlist`). Every other lookup is flat
    /// (`--flat-playlist`): a playlist, set or channel comes back as its entries in seconds (a SoundCloud set in single
    /// mode reads every track and times out), and a lone video is still read in full.
    public static func namesVideoInList(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false).lowercased()
        if path.contains("playlist") { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.contains(where: { $0.name == "list" && !($0.value ?? "").isEmpty }) else { return false }
        return namesAVideo(url, path: path, items: items)
    }

    // MARK: Kind of site

    /// Sites whose pages are music or podcasts: the picker and messages say "audio" and "tracks".
    public static let audioHosts = ["soundcloud.com", "bandcamp.com", "mixcloud.com", "audiomack.com"]
    /// Sites whose pages are videos.
    public static let videoHosts = ["youtube.com", "youtu.be", "vimeo.com", "twitter.com", "x.com", "tiktok.com",
                                    "instagram.com", "twitch.tv", "dailymotion.com"]

    /// What a page on this site usually holds; `.unknown` for any other site.
    public static func siteKind(_ url: URL) -> MediaKind {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return .unknown }
        func matches(_ list: [String]) -> Bool { list.contains { host == $0 || host.hasSuffix("." + $0) } }
        if matches(audioHosts) { return .audio }
        if matches(videoHosts) { return .video }
        return .unknown
    }

    private static func namesAVideo(_ url: URL, path: String, items: [URLQueryItem]) -> Bool {
        if items.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) { return true }
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let segments = path.split(separator: "/").map(String.init)
        if host == "youtu.be" || host.hasSuffix(".youtu.be") { return !segments.isEmpty }
        if let first = segments.first, ["shorts", "live", "embed", "v"].contains(first) { return segments.count >= 2 }
        return false
    }
}

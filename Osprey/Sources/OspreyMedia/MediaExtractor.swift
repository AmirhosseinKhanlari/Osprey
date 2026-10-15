import Foundation

public struct MediaExtractor: Sendable {
    public typealias Runner = @Sendable (URL, [String], TimeInterval) async throws -> ProcessResult

    private let tools: MediaTools
    private let runner: Runner

    public init(tools: MediaTools, runner: @escaping Runner = { try await ProcessRunner.run($0, $1, timeout: $2) }) {
        self.tools = tools
        self.runner = runner
    }

    public func probe(_ url: URL, cookieHeader: String?, playlist: Bool) async throws -> MediaProbeResult {
        // Only web pages: anything else (file:, a bare "--option") must never reach yt-dlp.
        guard MediaURL.isWebURL(url) else { throw MediaError.unsupported }
        guard let ytdlp = tools.locate(.ytdlp) else { throw MediaError.toolMissing("yt-dlp") }
        // The user's yt-dlp config files could rename outputs, break the JSON or add browser cookies.
        var args = ["--ignore-config", "-J", "--no-warnings", "--no-progress", playlist ? "--flat-playlist" : "--no-playlist"]
        var jar: CookieJarFile?
        if let header = cookieHeader, !header.isEmpty {
            let file = try CookieJarFile.write(cookieHeader: header, for: url)
            jar = file
            args += ["--cookies", file.url.path(percentEncoded: false)]
        }
        defer { jar?.delete() }
        args += ["--", url.absoluteString]          // `--`: the URL is never read as an option

        let result = try await runner(ytdlp.url, args, playlist ? 60 : 45)
        guard result.status == 0 else { throw Self.map(stderr: result.stderr) }
        let decoded: MediaProbeResult
        do { decoded = try MediaProbeResult.decode(result.stdout) } catch {
            throw MediaError.extractionFailed("unexpected output from yt-dlp")
        }
        if case .single(let info) = decoded, FormatCatalog.isFullyProtected(info) { throw MediaError.drmProtected }
        return decoded
    }

    // MARK: Error mapping

    /// Replaces every URL with its host so signed tokens never reach messages or logs.
    static func redactURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s'"<>)\]]+"#, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let host = URL(string: ns.substring(with: m.range))?.host(percentEncoded: false)
            result += host ?? "link"
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }

    static func map(stderr raw: String) -> MediaError {
        let text = redactURLs(raw)
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has("unsupported url") { return .unsupported }
        if has(#"\bdrm\b"#) { return .drmProtected }
        if has("sign in") || has("login") || has(#"\bage\b"#) || has("cookies") { return .loginRequired }
        if has("private video") || has("video unavailable") || has("not available in your country") || has("removed") { return .unavailable }
        // With -J, yt-dlp's progress lines come first on stderr: the ERROR line says what went wrong.
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let firstLine = lines.first { $0.hasPrefix("ERROR:") } ?? lines.first ?? "yt-dlp failed"
        return .extractionFailed(String(firstLine.prefix(200)))
    }
}

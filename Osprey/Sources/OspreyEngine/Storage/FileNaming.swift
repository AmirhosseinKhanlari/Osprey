import Foundation

public enum FileNaming {
    public static func name(from url: URL) -> String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return url.host() ?? "download" }
        return ContentDisposition.sanitize(last)
    }

    /// Finder-style de-duplication (`name 2.ext`); also skips names whose `.slpart` exists, and names a media merge is
    /// writing (`name.osprey-partial.ext`), so two merges of the same video never pick the same final name.
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func taken(_ url: URL) -> Bool {
            let path = url.path(percentEncoded: false)
            let stem = url.deletingPathExtension().lastPathComponent
            let merging = url.deletingLastPathComponent()
                .appending(path: ext.isEmpty ? "\(stem).osprey-partial" : "\(stem).osprey-partial.\(ext)").path(percentEncoded: false)
            return fm.fileExists(atPath: path) || fm.fileExists(atPath: path + ".slpart") || fm.fileExists(atPath: merging)
        }
        var candidate = folder.appending(path: name)
        var counter = 2
        while taken(candidate) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

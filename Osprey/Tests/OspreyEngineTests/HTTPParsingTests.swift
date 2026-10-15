import Foundation
import Testing
@testable import OspreyEngine

@Suite struct ContentDispositionTests {
    @Test func quotedFilename() {
        #expect(ContentDisposition.filename(from: #"attachment; filename="report.pdf""#) == "report.pdf")
    }

    @Test func extendedFilenameWins() {
        let header = #"attachment; filename="rates.txt"; filename*=UTF-8''%E2%82%AC%20rates.txt"#
        #expect(ContentDisposition.filename(from: header) == "€ rates.txt")
    }

    @Test func noFilename() {
        #expect(ContentDisposition.filename(from: "inline") == nil)
        #expect(ContentDisposition.filename(from: nil) == nil)
    }

    @Test func stripsPathsAndUnsafeCharacters() {
        #expect(ContentDisposition.filename(from: #"attachment; filename="../../etc/passwd""#) == "passwd")
        #expect(ContentDisposition.sanitize("a:b.txt") == "a-b.txt")
        #expect(ContentDisposition.sanitize(".hidden") == "_hidden")
        #expect(ContentDisposition.sanitize("   ") == "download")
    }

    @Test func longNameKeepsExtensionWithinByteLimit() {
        let result = ContentDisposition.sanitize(String(repeating: "a", count: 300) + ".zip")
        #expect(result.utf8.count <= 240)
        #expect(result.hasSuffix(".zip"))
    }

    @Test func multiByteNameTruncatesOnCharacterBoundary() {
        let result = ContentDisposition.sanitize(String(repeating: "é", count: 200))
        #expect(result.utf8.count <= 240)
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0 == "é" })
    }

    @Test func shortNameUnchanged() {
        #expect(ContentDisposition.sanitize("report.pdf") == "report.pdf")
    }
}

@Suite struct HTTPHeadersTests {
    @Test func contentRange() {
        #expect(HTTPHeaders.totalSize(fromContentRange: "bytes 0-0/1234") == 1234)
        #expect(HTTPHeaders.rangeStart(fromContentRange: "bytes 100-199/1234") == 100)
        #expect(HTTPHeaders.totalSize(fromContentRange: "bytes 0-0/*") == nil)
        #expect(HTTPHeaders.totalSize(fromContentRange: nil) == nil)
    }

    @Test func contentRangeEnd() {
        #expect(HTTPHeaders.rangeEnd(fromContentRange: "bytes 100-199/1234") == 199)
        #expect(HTTPHeaders.rangeEnd(fromContentRange: "bytes 100-199/*") == 199)
        #expect(HTTPHeaders.rangeEnd(fromContentRange: "bytes 0-0/1") == 0)
        #expect(HTTPHeaders.rangeEnd(fromContentRange: "bytes */1234") == nil)
        #expect(HTTPHeaders.rangeEnd(fromContentRange: "bytes 100-/1234") == nil)
        #expect(HTTPHeaders.rangeEnd(fromContentRange: nil) == nil)
    }

    @Test func retryAfterSecondsAndDate() {
        #expect(HTTPHeaders.retryAfter("120", now: Date()) == 120)
        let now = Date(timeIntervalSince1970: 1_445_412_450)   // Wed, 21 Oct 2015 07:27:30 GMT
        #expect(HTTPHeaders.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 30)
        #expect(HTTPHeaders.retryAfter("soon", now: now) == nil)
    }

    @Test func retryAfterRejectsNonDeltaSeconds() {
        let now = Date()
        #expect(HTTPHeaders.retryAfter("inf", now: now) == nil)
        #expect(HTTPHeaders.retryAfter("nan", now: now) == nil)
        #expect(HTTPHeaders.retryAfter("1e3", now: now) == nil)
        #expect(HTTPHeaders.retryAfter("-5", now: now) == nil)
        #expect(HTTPHeaders.retryAfter("  90 ", now: now) == 90)
    }
}

@Suite struct FileNamingTests {
    @Test func nameFromURL() {
        #expect(FileNaming.name(from: URL(string: "https://x.com/a/b/Xcode_26.1.xip?token=1")!) == "Xcode_26.1.xip")
        #expect(FileNaming.name(from: URL(string: "https://x.com/")!) == "x.com")
    }

    @Test func uniqueURLAvoidsFilesAndPartFiles() throws {
        let folder = TestTemp.root.appending(path: "naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FileNaming.uniqueURL(in: folder, name: "a.zip").lastPathComponent == "a.zip")
        FileManager.default.createFile(atPath: folder.appending(path: "a.zip").path(percentEncoded: false), contents: Data())
        FileManager.default.createFile(atPath: folder.appending(path: "a 2.zip.slpart").path(percentEncoded: false), contents: Data())
        #expect(FileNaming.uniqueURL(in: folder, name: "a.zip").lastPathComponent == "a 3.zip")
    }

    /// A merge in progress writes `<name>.osprey-partial.<ext>`; its final name is taken until it finishes.
    @Test func uniqueURLAvoidsNamesWithAMergeInProgress() throws {
        let folder = TestTemp.root.appending(path: "naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appending(path: "Clip [x].osprey-partial.mp4").path(percentEncoded: false), contents: Data())
        #expect(FileNaming.uniqueURL(in: folder, name: "Clip [x].mp4").lastPathComponent == "Clip [x] 2.mp4")
        FileManager.default.createFile(atPath: folder.appending(path: "noext.osprey-partial").path(percentEncoded: false), contents: Data())
        #expect(FileNaming.uniqueURL(in: folder, name: "noext").lastPathComponent == "noext 2")
    }
}

/// Cookie and Authorization go only to the origin the browser gave them for: same scheme, host and port.
@Suite struct CredentialScopeTests {
    func redirect(from: String, to: String) -> URLRequest {
        var request = URLRequest(url: URL(string: to)!)
        request.setValue("s=1", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        request.setValue("UA", forHTTPHeaderField: "User-Agent")
        let response = HTTPURLResponse(url: URL(string: from)!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        return HTTPHeaders.redirected(request, from: response)
    }

    @Test func httpsToHttpOnTheSameHostDropsCredentials() {
        let next = redirect(from: "https://x.test/a", to: "http://x.test/b")
        #expect(next.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(next.value(forHTTPHeaderField: "User-Agent") == "UA")
    }

    @Test func anotherPortOnTheSameHostDropsCredentials() {
        let next = redirect(from: "https://x.test/a", to: "https://x.test:8443/b")
        #expect(next.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func sameOriginKeepsCredentialsWithDefaultPortsNormalized() {
        let next = redirect(from: "https://X.test/a", to: "https://x.test:443/b")
        #expect(next.value(forHTTPHeaderField: "Cookie") == "s=1")
        #expect(next.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(HTTPHeaders.mayCarryCredentials(from: URL(string: "http://x.test:80/a"), to: URL(string: "http://x.test/b")))
    }

    @Test func scopeRules() {
        func may(_ a: String, _ b: String) -> Bool { HTTPHeaders.mayCarryCredentials(from: URL(string: a), to: URL(string: b)) }
        #expect(may("https://x.test/a", "https://x.test/b"))
        #expect(!may("https://x.test/a", "http://x.test/a"))        // never from https to http
        #expect(may("http://x.test/a", "https://x.test/a"))         // an upgrade to https on the same host is fine
        #expect(!may("http://x.test:8080/a", "https://x.test/a"))   // ...but not from a non-default port
        #expect(!may("https://x.test/a", "https://y.test/a"))
        #expect(!may("https://x.test/a", "https://x.test:444/a"))
        #expect(!may("https://x.test/a", "ftp://x.test/a"))
        #expect(!may("https://x.test/a", "not a url"))
    }
}

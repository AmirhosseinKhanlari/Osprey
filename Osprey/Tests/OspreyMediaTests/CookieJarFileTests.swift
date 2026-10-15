import Foundation
import Testing
@testable import OspreyMedia

@Suite struct CookieJarFileTests {
    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    @Test func writesNetscapeFileWithPrivateModes() throws {
        let jar = try CookieJarFile.write(cookieHeader: "SID=secret; HSID=x", for: URL(string: "https://www.youtube.com/watch?v=1")!)
        defer { jar.delete() }
        #expect(try mode(jar.url) == 0o600)
        #expect(try mode(jar.url.deletingLastPathComponent()) == 0o700)
        let lines = try String(contentsOf: jar.url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == "# Netscape HTTP Cookie File")
        #expect(lines.contains(".www.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tsecret"))
        #expect(lines.contains(".www.youtube.com\tTRUE\t/\tTRUE\t0\tHSID\tx"))
    }

    @Test func httpIsNotSecureAndEqualsInValuesSurvive() throws {
        let jar = try CookieJarFile.write(cookieHeader: "t=a=b==", for: URL(string: "http://x.test/")!)
        defer { jar.delete() }
        let text = try String(contentsOf: jar.url, encoding: .utf8)
        #expect(text.contains(".x.test\tTRUE\t/\tFALSE\t0\tt\ta=b=="))
    }

    @Test func skipsEmptyNamesAndControlCharacters() throws {
        let jar = try CookieJarFile.write(cookieHeader: "=novalue; ok=1; bad=a\tb; bad2=a\rb; bad3=a\nb; junk", for: URL(string: "https://x.test/")!)
        defer { jar.delete() }
        let lines = try String(contentsOf: jar.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.last == ".x.test\tTRUE\t/\tTRUE\t0\tok\t1")
    }

    @Test func deleteRemovesFileAndFolder() throws {
        let jar = try CookieJarFile.write(cookieHeader: "a=b", for: URL(string: "https://x.test/")!)
        let folder = jar.url.deletingLastPathComponent()
        jar.delete()
        #expect(!FileManager.default.fileExists(atPath: jar.url.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }
}

import Foundation
import OspreyBridge
import Testing
@testable import OspreyIntegration

actor OrderLog {
    private(set) var orders: [CaptureOrder] = []
    func add(_ order: CaptureOrder) { orders.append(order) }
}

func router(_ settings: IntegrationSettings = .default, accept: Bool = true, log: OrderLog = OrderLog()) -> CaptureRouter {
    CaptureRouter(appVersion: "0.1.0", settings: { settings }) { order, gate in
        guard gate.tryCommit() else { return false }   // what CaptureService does before adding
        await log.add(order)
        return accept
    }
}

@Suite struct CaptureRouterTests {
    @Test func helloReturnsVersionAndRules() async {
        let reply = await router().handle(.hello())
        #expect(reply == .hello(version: "0.1.0", rules: IntegrationSettings.default.rules))
        #expect(IntegrationSettings.default.rules.extensions.contains("zip"))
        #expect(IntegrationSettings.default.rules.extensions.contains("r0*"))
        #expect(!IntegrationSettings.default.captureInPrivate)
    }

    @Test func captureBuildsAnOrderWithHeadersAndName() async {
        let log = OrderLog()
        let reply = await router(log: log).handle(.capture(url: "https://x.test/f/a.zip", referrer: "https://x.test/page",
                                                           filename: "/Users/me/Downloads/a.zip", cookies: "s=1; t=2",
                                                           userAgent: "UA/1", source: .menu))
        #expect(reply.wasTaken)
        let order = await log.orders.first
        #expect(order?.url == URL(string: "https://x.test/f/a.zip"))
        #expect(order?.headers == ["Referer": "https://x.test/page", "Cookie": "s=1; t=2", "User-Agent": "UA/1"])
        #expect(order?.preferredFilename == "a.zip")
        #expect(order?.source == .menu)
    }

    @Test func refusesWhenDisabled() async {
        var settings = IntegrationSettings.default
        settings.enabled = false
        #expect(await router(settings).handle(.capture(url: "https://x.test/a.zip")) == .failure(.disabled))
    }

    @Test func refusesNonHTTPURLs() async {
        let log = OrderLog()
        let reply = await router(log: log).handle(.capture(url: "ftp://x.test/a.zip"))
        #expect(reply == .capture(taken: false, reason: "unsupported-url"))
        #expect(await log.orders.isEmpty)
    }

    @Test func privateWindowsNeedOptIn() async {
        #expect(await router().handle(.capture(url: "https://x.test/a.zip", isPrivate: true)) == .capture(taken: false, reason: "private"))
        var settings = IntegrationSettings.default
        settings.captureInPrivate = true
        #expect(await router(settings).handle(.capture(url: "https://x.test/a.zip", isPrivate: true)).wasTaken)
    }

    @Test func headerValuesWithLineBreaksAreDropped() async {
        let log = OrderLog()
        _ = await router(log: log).handle(.capture(url: "https://x.test/a.zip", cookies: "a=1\r\nX-Evil: 1", userAgent: "UA"))
        #expect(await log.orders.first?.headers == ["User-Agent": "UA"])
    }

    @Test func headerValuesWithControlCharactersAreDropped() async {
        let log = OrderLog()
        _ = await router(log: log).handle(.capture(url: "https://x.test/a.zip", referrer: "https://x.test/page",
                                                   cookies: "a=1\u{0}b", userAgent: "UA\u{7F}"))
        #expect(await log.orders.first?.headers == ["Referer": "https://x.test/page"])
    }

    @Test func filenameDegenerateNamesBecomeNil() async {
        let log = OrderLog()
        let r = router(log: log)
        for filename in ["/Users/me/Downloads/..", "   ", "/Users/me/Downloads/.", "/Users/me/Downloads/ ."] {
            _ = await r.handle(.capture(url: "https://x.test/a.zip", filename: filename))
        }
        #expect(await log.orders.map(\.preferredFilename) == [nil, nil, nil, nil])
    }

    @Test func filenameTakesLastComponentOfWindowsPaths() async {
        let log = OrderLog()
        _ = await router(log: log).handle(.capture(url: "https://x.test/a.zip", filename: "C:\\Users\\me\\a.zip"))
        #expect(await log.orders.first?.preferredFilename == "a.zip")
    }

    @Test func uppercaseSchemeAndHostAreAccepted() async {
        let log = OrderLog()
        #expect(await router(log: log).handle(.capture(url: "HTTPS://X.TEST/A.ZIP")).wasTaken)
        #expect(await log.orders.first?.url == URL(string: "HTTPS://X.TEST/A.ZIP"))
    }

    @Test func emptyHostIsUnsupported() async {
        let log = OrderLog()
        #expect(await router(log: log).handle(.capture(url: "http://")) == .capture(taken: false, reason: "unsupported-url"))
        #expect(await log.orders.isEmpty)
    }

    @Test func missingURLIsUnsupported() async {
        let log = OrderLog()
        var request = BridgeRequest.capture(url: "x")
        request.url = nil
        #expect(await router(log: log).handle(request) == .capture(taken: false, reason: "unsupported-url"))
        #expect(await log.orders.isEmpty)
    }

    // Userinfo is kept on the order's URL on purpose: the download engine needs it for HTTP basic auth.
    @Test func userinfoIsKeptOnTheOrderURL() async {
        let log = OrderLog()
        #expect(await router(log: log).handle(.capture(url: "https://user:pass@x.test/a.zip")).wasTaken)
        #expect(await log.orders.first?.url == URL(string: "https://user:pass@x.test/a.zip"))
    }

    @Test func helloReportsDisabledRules() async {
        var settings = IntegrationSettings.default
        settings.enabled = false
        let reply = await router(settings).handle(.hello())
        #expect(reply.ok)
        #expect(reply.rules?.enabled == false)
    }

    @Test func declinedOrdersAreReported() async {
        #expect(await router(accept: false).handle(.capture(url: "https://x.test/a.zip")) == .capture(taken: false, reason: "rejected"))
    }
}

@Suite struct IntegrationSettingsStoreTests {
    @Test func defaultsWhenEmptyAndRoundTrips() throws {
        let suite = "osprey-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IntegrationSettingsStore(defaults: defaults)
        #expect(store.settings == .default)
        var changed = IntegrationSettings.default
        changed.extensions = ["zip", "dmg"]
        changed.captureInPrivate = true
        store.settings = changed
        #expect(IntegrationSettingsStore(defaults: defaults).settings == changed)
    }

    @Test func progressWindowIsOnByDefault() {
        #expect(IntegrationSettings.default.showProgressWindow)
        #expect(IntegrationSettings(enabled: true, extensions: [], captureInPrivate: false).showProgressWindow)
    }

    @Test func olderJSONWithoutProgressWindowKeyDecodesWithDefault() throws {
        let json = Data(#"{"enabled":false,"extensions":["zip"],"captureInPrivate":true}"#.utf8)
        let decoded = try JSONDecoder().decode(IntegrationSettings.self, from: json)
        #expect(decoded == IntegrationSettings(enabled: false, extensions: ["zip"], captureInPrivate: true,
                                               showProgressWindow: true))
    }

    @Test func storeReadsOlderJSONAndRoundTripsTheProgressWindowSetting() throws {
        let suite = "osprey-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"enabled":true,"extensions":["dmg"],"captureInPrivate":false}"#.utf8), forKey: "integrationSettings")
        let store = IntegrationSettingsStore(defaults: defaults)
        #expect(store.settings.extensions == ["dmg"])
        #expect(store.settings.showProgressWindow)
        var changed = store.settings
        changed.showProgressWindow = false
        store.settings = changed
        #expect(IntegrationSettingsStore(defaults: defaults).settings.showProgressWindow == false)
    }
}

@Suite struct CaptureRouterGateTests {
    @Test func expiredRequestNeverReachesAccept() async {
        let log = OrderLog()
        let gate = CommitGate()
        gate.expire()
        let reply = await router(log: log).handle(.capture(url: "https://x.test/a.zip"), gate: gate)
        #expect(!reply.wasTaken)
        #expect(await log.orders.isEmpty)
    }

    @Test func acceptThatLosesTheRaceAddsNothing() async {
        let log = OrderLog()
        let gate = CommitGate()
        let r = CaptureRouter(appVersion: "0.1.0", settings: { .default }) { order, gate in
            gate.expire()                       // the server timed out while this was waiting
            guard gate.tryCommit() else { return false }
            await log.add(order)
            return true
        }
        #expect(await r.handle(.capture(url: "https://x.test/a.zip"), gate: gate) == .capture(taken: false, reason: "rejected"))
        #expect(await log.orders.isEmpty)
    }
}

@Suite struct MediaRouterTests {
    func mediaRouter(_ settings: IntegrationSettings = .default, log: MediaLog = MediaLog()) -> CaptureRouter {
        CaptureRouter(appVersion: "0.1.0", settings: { settings }, acceptMedia: { order in await log.add(order); return true },
                      accept: { _, _ in false })
    }

    @Test func acceptsAValidRequestWithSanitizedFields() async {
        let log = MediaLog()
        let reply = await mediaRouter(log: log).handle(.media(url: "https://x.test/watch?v=1", title: "Ti\u{7}tle\n" + String(repeating: "a", count: 400),
                                                           cookies: "a=1\r\nX: y", isPrivate: false, source: .button))
        #expect(reply == .capture(taken: true))
        let order = await log.orders.first
        #expect(order?.pageURL == URL(string: "https://x.test/watch?v=1"))
        #expect(order?.cookieHeader == nil)
        #expect(order?.title?.count == 300 && order?.title?.hasPrefix("Titlea") == true)
        #expect(order?.source == .button && order?.isPrivate == false)
        let ok = MediaLog()
        _ = await mediaRouter(log: ok).handle(.media(url: "https://x.test/w", cookies: "s=1; t=2"))
        #expect(await ok.orders.first?.cookieHeader == "s=1; t=2")
    }

    @Test func rejectsDisabledPrivateAndNonHTTP() async {
        let log = MediaLog()
        var off = IntegrationSettings.default
        off.enabled = false
        #expect(await mediaRouter(off, log: log).handle(.media(url: "https://x.test/w")) == .failure(.disabled))
        #expect(await mediaRouter(log: log).handle(.media(url: "ftp://x.test/w")) == .capture(taken: false, reason: "unsupported-url"))
        #expect(await mediaRouter(log: log).handle(.media(url: "https://x.test/w", isPrivate: true)) == .capture(taken: false, reason: "private"))
        #expect(await log.orders.isEmpty)
    }

    @Test func expiredGateNeverCommitsMedia() async {
        let log = MediaLog()
        let gate = CommitGate()
        gate.expire()
        let reply = await mediaRouter(log: log).handle(.media(url: "https://x.test/w"), gate: gate)
        #expect(!reply.wasTaken)
        #expect(await log.orders.isEmpty)
    }

    @Test func videoButtonFollowsSettings() {
        #expect(IntegrationSettings.default.rules.videoButton)
        var s = IntegrationSettings.default
        s.videoButton = false
        #expect(!s.rules.videoButton)
        #expect((try? JSONDecoder().decode(IntegrationSettings.self, from: Data(#"{"enabled":true}"#.utf8)))?.videoButton == true)
    }
}

actor MediaLog {
    private(set) var orders: [MediaOrder] = []
    func add(_ order: MediaOrder) { orders.append(order) }
}

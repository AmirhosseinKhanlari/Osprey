import Darwin
import Foundation
import Testing
@testable import OspreyBridge

/// Unix socket paths are limited to 103 bytes, so tests use short paths in /tmp.
func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/slb-\(UUID().uuidString.prefix(8)).sock")
}

actor Recorder {
    private(set) var requests: [BridgeRequest] = []
    func add(_ request: BridgeRequest) { requests.append(request) }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Sends raw bytes as one frame and returns the decoded reply (for malformed-request tests).
func sendRaw(_ json: String, to url: URL) throws -> BridgeResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = try SocketIO.makeAddress(url.path(percentEncoded: false))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(connected == 0)
    try SocketIO.writeAll(fd, try Frame.encode(Data(json.utf8)))
    let reply = try #require(try Frame.read(using: { try SocketIO.readExactly(fd, $0) }))
    return try JSONDecoder().decode(BridgeResponse.self, from: reply)
}

@Suite(.serialized) struct SocketTests {
    let rules = CaptureRules(enabled: true, extensions: ["zip"], captureInPrivate: false)

    @Test func helloRoundTrip() throws {
        let url = tempSocketURL()
        let rules = self.rules
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .hello(version: "9.9", rules: rules) }
        try server.start()
        defer { server.stop() }
        let reply = try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(.hello())
        #expect(reply == .hello(version: "9.9", rules: rules))
    }

    @Test func captureFieldsReachTheHandler() async throws {
        let url = tempSocketURL()
        let recorder = Recorder()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { request, _ in
            await recorder.add(request)
            return .capture(taken: true)
        }
        try server.start()
        defer { server.stop() }
        let request = BridgeRequest.capture(url: "https://x.test/a.zip", referrer: "https://x.test/", cookies: "s=1",
                                            userAgent: "UA", isPrivate: false, source: .auto)
        let reply = try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(request)
        #expect(reply.wasTaken)
        #expect(await recorder.requests == [request])
    }

    @Test func socketFileIsOwnerOnly() throws {
        let url = tempSocketURL()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .capture(taken: false) }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func wrongVersionAndBadRequestsGetErrorCodes() throws {
        let url = tempSocketURL()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        #expect(try sendRaw(#"{"v":2,"type":"hello"}"#, to: url) == .failure(.unsupportedVersion))
        #expect(try sendRaw(#"{"v":1,"type":"bogus"}"#, to: url) == .failure(.badRequest))
        #expect(try sendRaw("not json", to: url) == .failure(.badRequest))
    }

    @Test func deniedPeersGetNoReply() throws {
        let url = tempSocketURL()
        let calls = CallCounter()
        let server = BridgeServer(socketURL: url, verifier: DenyAllPeerVerifier()) { _, _ in calls.increment(); return .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        #expect(throws: BridgeClientError.noReply) { try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(.hello()) }
        #expect(calls.count == 0)
    }

    @Test func codeSignatureVerifierRejectsThisUnsignedTestProcess() throws {
        let url = tempSocketURL()
        let verifier = CodeSignaturePeerVerifier(teamID: BridgeLocation.teamID,
                                                 identifiers: [BridgeLocation.hostIdentifier, BridgeLocation.safariExtensionIdentifier])
        let calls = CallCounter()
        let server = BridgeServer(socketURL: url, verifier: verifier) { _, _ in calls.increment(); return .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        #expect(throws: BridgeClientError.noReply) { try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(.hello()) }
        #expect(calls.count == 0)
    }

    @Test func requirementNamesTeamAndIdentifiers() {
        let verifier = CodeSignaturePeerVerifier(teamID: "8CG9QYMSR5", identifiers: ["a.b", "c.d"])
        #expect(verifier.requirement ==
            #"anchor apple generic and certificate leaf[subject.OU] = "8CG9QYMSR5" and (identifier "a.b" or identifier "c.d")"#)
    }

    static let captureRequest = BridgeRequest.capture(url: "https://x.test/a.zip", referrer: nil, cookies: nil,
                                                      userAgent: "UA", isPrivate: false, source: .auto)

    @Test func clientLaunchesTheAppWhenNothingListens() throws {
        let url = tempSocketURL()
        let rules = self.rules
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .hello(version: "1", rules: rules) }
        // The delayed start and the final stop share a lock, so a client that gives up first can't leave a listener behind.
        let gate = NSLock()
        nonisolated(unsafe) var finished = false
        defer { gate.withLock { finished = true; server.stop() } }
        let launches = CallCounter()
        let client = BridgeClient(socketURL: url, timing: .init(launchWait: 5), serverVerifier: AllowAllPeerVerifier()) {
            launches.increment()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {   // the "app" starts a moment later
                gate.withLock { if !finished { try? server.start() } }
            }
            return true
        }
        #expect(try client.send(Self.captureRequest).ok)
        #expect(launches.count == 1)
    }

    @Test func clientLaunchesTheAppForMedia() throws {
        let url = tempSocketURL()
        let rules = self.rules
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .capture(taken: true) }
        _ = rules
        let gate = NSLock()
        nonisolated(unsafe) var finished = false
        defer { gate.withLock { finished = true; server.stop() } }
        let launches = CallCounter()
        let client = BridgeClient(socketURL: url, timing: .init(launchWait: 5), serverVerifier: AllowAllPeerVerifier()) {
            launches.increment()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                gate.withLock { if !finished { try? server.start() } }
            }
            return true
        }
        #expect(try client.send(.media(url: "https://x.test/watch")).wasTaken)
        #expect(launches.count == 1)
    }

    @Test func clientGivesUpAfterTheLaunchTimeout() {
        let client = BridgeClient(socketURL: tempSocketURL(), timing: .init(launchWait: 0.3), serverVerifier: AllowAllPeerVerifier()) { true }
        let started = Date()
        #expect(throws: BridgeClientError.unavailable) { try client.send(Self.captureRequest) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func clientFailsFastWhenTheAppIsNotInstalled() {
        let launches = CallCounter()
        let client = BridgeClient(socketURL: tempSocketURL(), timing: .init(launchWait: 3), serverVerifier: AllowAllPeerVerifier()) { launches.increment(); return false }
        let started = Date()
        #expect(throws: BridgeClientError.unavailable) { try client.send(Self.captureRequest) }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(launches.count == 1)
    }

    @Test func helloNeverLaunchesTheAppAndReportsNotRunning() {
        let launches = CallCounter()
        let client = BridgeClient(socketURL: tempSocketURL(), timing: .init(launchWait: 5), serverVerifier: AllowAllPeerVerifier()) { launches.increment(); return true }
        let started = Date()
        #expect(throws: BridgeClientError.notRunning) { try client.send(.hello()) }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(launches.count == 0)
    }

    // Debug builds (tests, unsigned SwiftPM runs) honour the override; release builds compile it out.
    @Test func socketOverrideVariableWinsOnlyWhenAllowed() {
        let env = [BridgeLocation.socketOverrideVariable: "/tmp/override.sock"]
        let url = BridgeLocation.defaultSocketURL(environment: env, allowsOverride: true)
        #expect(url.path(percentEncoded: false) == "/tmp/override.sock")
        let empty = BridgeLocation.defaultSocketURL(environment: [BridgeLocation.socketOverrideVariable: ""], allowsOverride: true)
        #expect(empty == BridgeLocation.groupSocketURL())
        let refused = BridgeLocation.defaultSocketURL(environment: env, allowsOverride: false)
        #expect(refused == BridgeLocation.groupSocketURL())
        #expect(refused.lastPathComponent == "bridge.sock")
    }

    @Test func clientRefusesAServerThatIsNotOsprey() throws {
        let url = tempSocketURL()
        let calls = CallCounter()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in calls.increment(); return .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        // This test process (the server here) is unsigned, so the real check must refuse it before sending anything.
        let client = BridgeClient(socketURL: url, serverVerifier: BridgeClient.defaultServerVerifier(), launcher: nil)
        #expect(throws: BridgeClientError.untrustedServer) { try client.send(Self.captureRequest) }
        #expect(calls.count == 0)
        let denied = BridgeClient(socketURL: url, serverVerifier: DenyAllPeerVerifier(), launcher: nil)
        #expect(throws: BridgeClientError.untrustedServer) { try denied.send(.hello()) }
        #expect(calls.count == 0)
    }

    @Test func defaultServerVerifierRequiresTheSignedApp() throws {
        let verifier = try #require(BridgeClient.defaultServerVerifier() as? CodeSignaturePeerVerifier)
        #expect(verifier.requirement ==
            #"anchor apple generic and certificate leaf[subject.OU] = "8CG9QYMSR5" and (identifier "com.akhanlari.osprey")"#)
    }

    @Test func serverKeepsServingAfterManyConnections() throws {
        let url = tempSocketURL()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        let client = BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil)
        for _ in 0..<200 { #expect(try client.send(.hello()).wasTaken) }
    }

    @Test func acceptLoopSurvivesAcceptErrors() throws {
        let url = tempSocketURL()
        let failures = CallCounter()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier(), replyTimeout: 3,
                                  acceptFunction: { fd in
            if failures.count < 3 { failures.increment(); errno = failures.count == 1 ? EMFILE : ECONNABORTED; return -1 }
            return Darwin.accept(fd, nil, nil)
        }) { _, _ in .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        #expect(try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(.hello()).wasTaken)
        #expect(failures.count == 3)
    }

    @Test func handlerThatNeverReturnsYieldsInternalError() throws {
        let url = tempSocketURL()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier(), replyTimeout: 0.3,
                                  acceptFunction: { Darwin.accept($0, nil, nil) }) { _, _ in
            try? await Task.sleep(for: .seconds(3))
            return .capture(taken: true)
        }
        try server.start()
        defer { server.stop() }
        let started = Date()
        #expect(try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(.hello()) == .failure(.internalError))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func tooLongSocketPathThrowsPromptlyWithoutLaunching() {
        let url = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120) + ".sock")
        let launches = CallCounter()
        let client = BridgeClient(socketURL: url, timing: .init(launchWait: 5), serverVerifier: AllowAllPeerVerifier()) { launches.increment(); return true }
        let started = Date()
        #expect(throws: SocketError(code: ENAMETOOLONG, operation: "address")) { try client.send(.hello()) }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(launches.count == 0)
    }

    @Test func startingTwiceThrowsAndKeepsServing() throws {
        let url = tempSocketURL()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in .capture(taken: true) }
        try server.start()
        defer { server.stop() }
        #expect(throws: SocketError(code: EALREADY, operation: "start")) { try server.start() }
        #expect(try BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil).send(.hello()).wasTaken)
    }

    @Test func stopThenNewServerOnSamePathNeverReachesTheOldOne() throws {
        let url = tempSocketURL()
        let oldCalls = CallCounter()
        let old = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in oldCalls.increment(); return .capture(taken: false) }
        try old.start()
        old.stop()
        let newCalls = CallCounter()
        let replacement = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier()) { _, _ in newCalls.increment(); return .capture(taken: true) }
        try replacement.start()
        defer { replacement.stop() }
        let client = BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil)
        for _ in 0..<20 { #expect(try client.send(.hello()).wasTaken) }
        #expect(oldCalls.count == 0)
        #expect(newCalls.count == 20)
    }
}


/// A late answer must never turn into a second download: see `CommitGate`.
@Suite(.serialized) struct LateCaptureTests {
    @Test func gateCommitsOnceAndRefusesAfterExpiry() {
        let gate = CommitGate()
        #expect(gate.tryCommit())
        #expect(gate.tryCommit())
        #expect(!gate.expire())          // committed first: the server must wait for the real reply
        #expect(!gate.isExpired)
        let late = CommitGate()
        #expect(late.expire())
        #expect(!late.tryCommit())       // expired first: the handler must not act
        #expect(late.isExpired)
    }

    @Test func handlerFinishingAfterTheTimeoutNeverCommits() async throws {
        let url = tempSocketURL()
        let acted = CallCounter()
        let refused = CallCounter()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier(), replyTimeout: 0.3,
                                  acceptFunction: { Darwin.accept($0, nil, nil) }) { _, gate in
            try? await Task.sleep(for: .milliseconds(800))   // e.g. a busy main actor
            guard gate.tryCommit() else { refused.increment(); return .capture(taken: false) }
            acted.increment()                                 // stands for addCaptured
            return .capture(taken: true)
        }
        try server.start()
        defer { server.stop() }
        let client = BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil)
        #expect(try client.send(SocketTests.captureRequest) == .failure(.internalError))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(acted.count == 0)
        #expect(refused.count == 1)
    }

    @Test func handlerThatCommittedInTimeIsAwaitedPastTheTimeout() throws {
        let url = tempSocketURL()
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier(), replyTimeout: 0.3,
                                  acceptFunction: { Darwin.accept($0, nil, nil) }) { _, gate in
            guard gate.tryCommit() else { return .capture(taken: false) }
            try? await Task.sleep(for: .milliseconds(600))   // committed, then slow to finish
            return .capture(taken: true)
        }
        try server.start()
        defer { server.stop() }
        let client = BridgeClient(socketURL: url, serverVerifier: AllowAllPeerVerifier(), launcher: nil)
        #expect(try client.send(SocketTests.captureRequest) == .capture(taken: true))
    }
}

/// The client's time limits nest inside the extension's capture timeout (see `BridgeTimeouts`).
@Suite(.serialized) struct CaptureBudgetTests {
    @Test func defaultTimeoutsNest() throws {
        #expect(BridgeTimeouts.handler < BridgeTimeouts.replyWait)
        #expect(BridgeServer.handlerTimeout == BridgeTimeouts.handler)
        #expect(BridgeTimeouts.launchWait + BridgeTimeouts.replyWait <= BridgeTimeouts.captureBudget)
        #expect(BridgeTimeouts.captureBudget < BridgeTimeouts.extensionCapture)
        let standard = BridgeClient.Timing.standard
        #expect(standard.launchDeadline(from: 0) + standard.receiveTimeout(elapsed: standard.launchDeadline(from: 0))
                <= BridgeTimeouts.captureBudget)
        // The extensions' timeout lives in rules.js; keep the two in step.
        let rules = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../Extensions/shared/rules.js")
        let source = try String(contentsOf: rules, encoding: .utf8)
        #expect(source.contains("CAPTURE_TIMEOUT_MS = \(Int(BridgeTimeouts.extensionCapture * 1000));"))
    }

    @Test func launchWaitLeavesRoomForAFullReplyWait() {
        let timing = BridgeClient.Timing(budget: 2, launchWait: 5, replyWait: 1.5)
        #expect(timing.launchDeadline(from: 10) == 10.5)
        #expect(timing.receiveTimeout(elapsed: 0.2) == 1.5)
        #expect(abs(timing.receiveTimeout(elapsed: 1.2) - 0.8) < 0.000_1)
        #expect(timing.receiveTimeout(elapsed: 3) == 0.05)
    }

    @Test func slowLaunchAndHungAppStillFinishWithinTheBudget() throws {
        let url = tempSocketURL()
        // The app comes up late and then never answers (its own handler timeout is far away).
        let server = BridgeServer(socketURL: url, verifier: AllowAllPeerVerifier(), replyTimeout: 10,
                                  acceptFunction: { Darwin.accept($0, nil, nil) }) { _, _ in
            try? await Task.sleep(for: .seconds(10))
            return .capture(taken: true)
        }
        let gate = NSLock()
        nonisolated(unsafe) var finished = false
        defer { gate.withLock { finished = true; server.stop() } }
        let timing = BridgeClient.Timing(budget: 1.2, launchWait: 1, replyWait: 0.8)
        let client = BridgeClient(socketURL: url, timing: timing, serverVerifier: AllowAllPeerVerifier()) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.withLock { if !finished { try? server.start() } } }
            return true
        }
        let started = Date()
        #expect(throws: BridgeClientError.noReply) { try client.send(SocketTests.captureRequest) }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.9)                 // it did wait for the reply...
        #expect(elapsed < timing.budget + 0.2)  // ...but never past the budget
    }

    @Test func helloSkipsTheLaunchWait() {
        let client = BridgeClient(socketURL: tempSocketURL(), serverVerifier: AllowAllPeerVerifier()) { true }
        let started = Date()
        #expect(throws: BridgeClientError.notRunning) { try client.send(.hello()) }
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}

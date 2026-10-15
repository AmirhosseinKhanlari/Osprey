import Foundation
import Testing
@testable import OspreyMedia

@Suite struct ProcessRunnerGroupTests {
    @Test func returnsPromptlyWhenAGrandchildHoldsStdout() async throws {
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(stdoutLines: ["hello"], grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile) }
        let start = Date()
        let result = try await ProcessRunner.run(fake.executable, [], timeout: 20)
        #expect(Date().timeIntervalSince(start) < 6)
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("hello"))
        let pid = try #require(readPID(pidFile))
        #expect(await waitUntil(timeout: 3) { processIsGone(pid) })
    }

    @Test func timeoutKillsTheWholeGroup() async throws {
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(hang: true, grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile) }
        await #expect(throws: MediaError.timedOut) {
            _ = try await ProcessRunner.run(fake.executable, [], timeout: 1)
        }
        let pid = try #require(readPID(pidFile))
        #expect(await waitUntil(timeout: 3) { processIsGone(pid) })
    }

    @Test func cancellationKillsTheWholeGroup() async throws {
        let pidFile = TestTemp.root.appending(path: "gc-\(UUID().uuidString).pid")
        let fake = try FakeTool(hang: true, grandchildPIDFile: pidFile)
        defer { fake.cleanUp(); try? FileManager.default.removeItem(at: pidFile) }
        let task = Task { try await ProcessRunner.run(fake.executable, [], timeout: 30) }
        #expect(await waitUntil { readPID(pidFile) != nil })
        let pid = try #require(readPID(pidFile))
        task.cancel()
        _ = try? await task.value
        #expect(await waitUntil(timeout: 4) { processIsGone(pid) })
    }

    @Test func missingExecutableIsToolMissing() async {
        await #expect(throws: MediaError.toolMissing("nope")) {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/nope"), [], timeout: 5)
        }
    }
}

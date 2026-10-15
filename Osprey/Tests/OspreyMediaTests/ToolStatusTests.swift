import Foundation
import Testing
@testable import OspreyMedia

@MainActor @Suite struct ToolStatusTests {
    /// A stand-in installer: records calls and, when `hold` is set, waits until `release()`.
    final class FakeInstaller: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        var hold = false
        var result: Result<ToolLocation, any Error> = .success(ToolLocation(url: URL(fileURLWithPath: "/tmp/managed/yt-dlp"), source: .managed))
        var backoff: TimeInterval?
        var progressValues: [Double] = []

        var calls: [String] { lock.withLock { _calls } }

        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                released = true
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }

        private func perform(_ name: String, _ progress: @Sendable (Double) -> Void) async throws -> ToolLocation {
            lock.withLock { _calls.append(name) }
            for value in progressValues { progress(value) }
            if hold {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { () -> Bool in
                        if released { return true }
                        waiters.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            return try result.get()
        }

        var installer: ToolStatus.Installer {
            ToolStatus.Installer(updateYtDlp: { try await self.perform("update", $0) },
                                 installManaged: { tool, progress in try await self.perform("install \(tool)", progress) },
                                 backoffRemaining: { _ in self.backoff },
                                 lastUpdateCheck: { nil })
        }
    }

    private func makeStatus(_ fake: FakeInstaller) -> ToolStatus {
        ToolStatus(tools: MediaTools(managedFolder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), homebrewFolders: []),
                   installer: fake.installer)
    }

    @Test func installThatFallsBackToHomebrewReportsAnError() async {
        let fake = FakeInstaller()
        fake.result = .success(ToolLocation(url: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"), source: .homebrew))
        let status = makeStatus(fake)
        await status.install(.ytdlp)?.value
        #expect(status.error(.ytdlp) == "Couldn't download yt-dlp. Using Homebrew's copy for now.")
        #expect(!status.isBusy(.ytdlp))
    }

    @Test func failedInstallReportsTheReason() async {
        let fake = FakeInstaller()
        fake.result = .failure(MediaError.installFailed("download failed"))
        let status = makeStatus(fake)
        await status.install(.ffmpeg)?.value
        #expect(status.error(.ffmpeg) == "Couldn't download ffmpeg (download failed).")
        #expect(fake.calls == ["install ffmpeg"])
    }

    @Test func successfulUpdateClearsAnEarlierError() async {
        let fake = FakeInstaller()
        fake.result = .failure(MediaError.installFailed("checksum mismatch"))
        let status = makeStatus(fake)
        await status.updateYtDlp()?.value
        #expect(status.error(.ytdlp) == "Couldn't download yt-dlp (checksum mismatch).")
        fake.result = .success(ToolLocation(url: URL(fileURLWithPath: "/tmp/managed/yt-dlp"), source: .managed))
        await status.updateYtDlp()?.value
        #expect(status.error(.ytdlp) == nil)
        #expect(fake.calls == ["update", "update"])
    }

    @Test func secondPressWhileBusyIsIgnored() async {
        let fake = FakeInstaller()
        fake.hold = true
        let status = makeStatus(fake)
        let first = status.updateYtDlp()
        #expect(first != nil)
        #expect(status.isBusy(.ytdlp))
        #expect(status.updateYtDlp() == nil)
        #expect(status.install(.ytdlp) == nil)
        // Another tool is independent.
        fake.hold = false
        await status.install(.ffmpeg)?.value
        fake.release()
        await first?.value
        #expect(fake.calls.filter { $0 == "update" || $0 == "install ytdlp" } == ["update"])
        #expect(fake.calls.contains("install ffmpeg"))
        #expect(!status.isBusy(.ytdlp))
    }

    @Test func backedOffToolIsNotTried() async {
        let fake = FakeInstaller()
        fake.backoff = 300
        let status = makeStatus(fake)
        #expect(status.install(.ffmpeg) == nil)
        #expect(status.updateYtDlp() == nil)
        #expect(fake.calls.isEmpty)
        #expect(status.backoffRemaining(.ffmpeg) == 300)
        #expect(!status.isBusy(.ffmpeg))
    }

    @Test func progressNeverGoesBackwards() async throws {
        let fake = FakeInstaller()
        fake.hold = true
        let status = makeStatus(fake)
        let task = status.updateYtDlp()
        let run = try #require(status.currentRun(.ytdlp))
        status.report(0.6, for: .ytdlp, run: run)
        status.report(0.3, for: .ytdlp, run: run)
        #expect(status.fraction(.ytdlp) == 0.6)
        status.report(0.8, for: .ytdlp, run: UUID())          // a stale run's report is dropped
        #expect(status.fraction(.ytdlp) == 0.6)
        status.report(0.9, for: .ytdlp, run: run)
        #expect(status.fraction(.ytdlp) == 0.9)
        fake.release()
        await task?.value
        status.report(1, for: .ytdlp, run: run)               // after the end: no progress comes back
        #expect(!status.isBusy(.ytdlp))
    }

    @Test func shortVersionTrimsFFmpegsBanner() {
        #expect(ToolStatus.shortVersion("2026.08.19") == "2026.08.19")
        #expect(ToolStatus.shortVersion("ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers") == "8.0.1")
        #expect(ToolStatus.shortVersion("ffmpeg version n9.0.2-static https://www.martin-riedl.de") == "n9.0.2-static")
        #expect(ToolStatus.shortVersion(nil) == nil)
        #expect(ToolStatus.shortVersion("") == nil)
    }
}

import Foundation
import Testing
import OspreyEngine
@testable import OspreyLibrary

@Suite struct ResumeFailureTextTests {
    @Test func aChangedFileAsksForARestart() throws {
        let engine = try #require(EngineError.remoteFileChanged.errorDescription)
        #expect(ResumeFailureText.isChangedOnServer(engine))
        #expect(ResumeFailureText.message(for: engine, restored: true, hasStoredCredentials: true) == "Changed on the server — Restart")
        #expect(ResumeFailureText.message(for: engine, restored: false, hasStoredCredentials: false) == "Changed on the server — Restart")
    }

    @Test func aRefusedRestoredDownloadWithoutCookiesNeedsSignIn() throws {
        for code in [401, 403] {
            let engine = try #require(EngineError.httpStatus(code, retryAfter: nil).errorDescription)
            #expect(ResumeFailureText.message(for: engine, restored: true, hasStoredCredentials: false)
                    == "Needs sign-in — download it again from your browser")
            #expect(ResumeFailureText.message(for: engine, restored: true, hasStoredCredentials: true) == nil)
            #expect(ResumeFailureText.message(for: engine, restored: false, hasStoredCredentials: false) == nil)
        }
    }

    @Test func otherFailuresKeepTheEngineText() throws {
        let notFound = try #require(EngineError.httpStatus(404, retryAfter: nil).errorDescription)
        #expect(ResumeFailureText.message(for: notFound, restored: true, hasStoredCredentials: false) == nil)
        #expect(ResumeFailureText.message(for: "The server stopped responding.", restored: true, hasStoredCredentials: false) == nil)
        #expect(!ResumeFailureText.isChangedOnServer("The server stopped responding."))
    }
}

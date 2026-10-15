import Testing
@testable import OspreyIntegration

@Suite("IntegrationSettings.parseExtensions")
struct ParseExtensionsTests {
    @Test func normalisesSplitsAndDeduplicates() {
        #expect(IntegrationSettings.parseExtensions(".ZIP, zip\n r0*  ;.dmg.") == ["zip", "r0*", "dmg"])
    }

    @Test func emptyAndSeparatorOnlyInputGiveNoExtensions() {
        #expect(IntegrationSettings.parseExtensions("").isEmpty)
        #expect(IntegrationSettings.parseExtensions(" , ;\n . ..").isEmpty)
    }

    @Test func preservesFirstOccurrenceOrder() {
        #expect(IntegrationSettings.parseExtensions("b a B c a") == ["b", "a", "c"])
    }
}

@Suite("CaptureNotificationText")
struct CaptureNotificationTextTests {
    @Test func namedForNormalCaptures() {
        #expect(CaptureNotificationText.title(fileName: "a.zip", isPrivate: false) == "Downloading a.zip")
    }

    @Test func genericForPrivateCaptures() {
        let title = CaptureNotificationText.title(fileName: "secret.zip", isPrivate: true)
        #expect(title == "Downloading a file")
        #expect(!title.contains("secret"))
    }
}

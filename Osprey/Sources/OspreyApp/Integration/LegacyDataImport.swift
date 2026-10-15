import Foundation
import OspreyBridge
import OspreyIntegration

/// Imports the former app's settings, tools and browser setup the first time Osprey runs (see `LegacyMigration`).
enum LegacyDataImport {
    /// Runs at most once per process, before anything reads the defaults: both the App and its delegate touch it
    /// first thing, since SwiftUI doesn't promise which of them it creates first. Only the signed app bundle imports:
    /// a `swift run` build has no bundle ID and must not delete the installed app's browser manifests.
    static let once: Void = {
        guard Bundle.main.bundleIdentifier == BridgeLocation.appBundleID else { return }
        let outcome = LegacyMigration().run()
        guard !outcome.alreadyDone else { return }
        NSLog("Osprey: first-launch import: %@", outcome.summary)
    }()
}

import AppKit
import OspreyBridge
import OspreyIntegration
import SwiftUI

@main
struct OspreyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = Appearance.system

    private static let hasMenuBarGlyph = NSImage(named: "MenuBarGlyph") != nil

    init() {
        _ = LegacyDataImport.once   // before anything below reads the defaults
        NSApplication.shared.setActivationPolicy(.regular)   // needed when launched via `swift run`
    }

    var body: some Scene {
        // A single window: reopening it from the menu bar brings it back instead of adding another.
        Window("Osprey", id: "main") {
            ContentView()
                .environment(appDelegate.manager)
                .environment(appDelegate.media)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 1_280, minHeight: 680)
                .task {
                    appDelegate.startCapture()   // no-op once running; retries after a failed start
                }
                .background { MainWindowOpenerRegistration(panels: appDelegate.panels) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            FindCommand()
            CommandMenu("Downloads") {
                Button("Pause All") { appDelegate.manager.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Resume All") { appDelegate.manager.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.manager)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            // The glyph lives in the app's asset catalog; a `swift run` build has none, so it falls back to a symbol.
            if Self.hasMenuBarGlyph {
                Label("Osprey", image: "MenuBarGlyph")
            } else {
                Label("Osprey", systemImage: "arrow.down.circle")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.media)
                .environment(appDelegate.toolStatus)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

import AppKit
import SwiftUI

/// Minimal read-only viewer (P0.5).
///
/// Scope is deliberately tiny: open the default library, list collections, show a
/// scrollable thumbnail grid. No import UI, no canvas, no thumb pipeline.
///
/// P1-D adds one `AppearanceStore` at the root: every window and the Settings scene read
/// the same tokens, so a settings change re-renders in place. Nothing is recreated, which
/// is why a light/dark flip does not flash.
///
/// P1-E adds one `CaptureCenter` at the root: it owns the menu-bar pin (which must outlive
/// a window) and is the single funnel for window drops, sidebar drops and ⌘V.
@main
struct AtlasOSSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LibraryModel()
    @StateObject private var appearance = AppearanceStore()
    @StateObject private var capture = CaptureCenter()

    var body: some Scene {
        Window("AtlasOSS", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(capture)
                .environment(\.appearance, appearance.tokens)
                .preferredColorScheme(appearance.tokens.colorScheme.swiftUI)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    model.open()
                    // Idempotent: installs the status item once the NSApp run loop is up.
                    capture.attach(model)
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AppearanceCommands()
        }

        // Standard "AtlasOSS → Settings…" (⌘,). The scene is separate from the main
        // window, so settings can be open while the grid updates behind it.
        Settings {
            AppearanceSettingsView()
                .environmentObject(appearance)
                .environment(\.appearance, appearance.tokens)
                .preferredColorScheme(appearance.tokens.colorScheme.swiftUI)
        }
    }
}

/// A second, explicitly named entry point beside the standard "Settings…" item SwiftUI
/// installs for the `Settings` scene. An SPM executable launched from a terminal does not
/// always get the app-menu plumbing, so the command is registered explicitly.
private struct AppearanceCommands: Commands {
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Appearance Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command, .option])
        }
    }
}

/// An SPM executable is not a bundled `.app`, so it launches as an accessory
/// process. Promote it to a regular app and bring the window forward.
///
/// P1-E note: `applicationShouldTerminateAfterLastWindowClosed` stays `true`. A menu-bar
/// pin normally implies an agent process that outlives its window, but making the app
/// windowless would have to solve window *recreation* (the SwiftUI `Window` scene cannot be
/// reopened from AppKit without `openWindow`), and a half-working version is worse than a
/// documented limit. The pin therefore covers the real use case — the window is open but
/// behind other apps — and quitting (⌘Q, or the pin's right-click menu) removes it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

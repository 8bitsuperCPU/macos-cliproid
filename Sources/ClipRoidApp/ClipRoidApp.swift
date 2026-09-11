import SwiftUI
import AppKit
import ClipRoidUI
import ClipRoidKit

/// This file must not be named main.swift — SwiftPM treats that name as top-level code and @main
/// then conflicts with it.
@main
struct ClipRoidApp: App {
    @State private var environment: AppEnvironment

    init() {
        // Set before anything else is built. A SwiftPM executable run via `swift run` has no
        // Info.plist, so LaunchServices treats it as a background-only process: no menu bar, no
        // activation, and keychain prompts that never come to the front. Same fix, and same reason,
        // as ~/projects/nyx/Sources/nyx/NyxApp.swift.
        NSApplication.shared.setActivationPolicy(.regular)
        _environment = State(initialValue: AppEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .frame(minWidth: 420, minHeight: 320)
                .task { await environment.start() }
        }
        .defaultSize(width: 520, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("ClipRoid", systemImage: "doc.on.clipboard") {
            Button("Open ClipRoid") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit ClipRoid") {
                Task {
                    await environment.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        }
    }
}

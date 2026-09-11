import SwiftUI
import AppKit
import ClipRoidUI
import ClipRoidKit
import ClipRoidCore

/// This file must not be named main.swift — SwiftPM treats that name as top-level code and @main
/// then conflicts with it.
/// Keeps the app alive when its windows are closed, and records why it is shutting down.
///
/// Without `applicationShouldTerminateAfterLastWindowClosed` returning false, closing the ClipRoid
/// window quits the process — which for a clipboard manager means capture silently stops and the
/// global hotkey silently dies. The failure presents as "Ctrl+Cmd+V doesn't work any more", with
/// nothing in the logs and no crash report, because the exit was perfectly clean.
///
/// Spec §12 rules out a menu-bar-only app, so ClipRoid has real windows — which makes closing one
/// an ordinary thing for a user to do, and makes this the single most likely way to break the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (@MainActor () async -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.log("ClipRoid terminating")
    }

    /// Reopening from the Dock or Spotlight should bring the window back rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}

@main
struct ClipRoidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var quickPaste: QuickPastePanel?

    init() {
        // Set before anything else is built. A SwiftPM executable run via `swift run` has no
        // Info.plist, so LaunchServices treats it as a background-only process: no menu bar, no
        // activation, and keychain prompts that never come to the front. Same fix, and same reason,
        // as ~/projects/nyx/Sources/nyx/NyxApp.swift.
        NSApplication.shared.setActivationPolicy(.regular)
        _environment = State(initialValue: AppEnvironment())
    }

    /// Builds the panel and points the hotkeys at it. Ordering matters: the callbacks have to be
    /// in place before `registerHotKeys()`, or the first press goes nowhere.
    @MainActor
    private func installQuickPaste() {
        guard quickPaste == nil else { return }
        Diagnostics.log("Installing Quick Paste panel")
        // Report the window inventory shortly after launch. A SwiftUI app that silently fails to
        // open its main window looks identical, from outside, to one that opened it fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let windows = NSApplication.shared.windows
            Diagnostics.log("Windows: \(windows.count) — " + windows.map {
                "\(type(of: $0))(visible=\($0.isVisible) title=\"\($0.title)\" size=\(Int($0.frame.width))x\(Int($0.frame.height)))"
            }.joined(separator: ", "))
        }
        let model = QuickPasteViewModel(store: environment.store, coordinator: environment.paste)
        let panel = QuickPastePanel(model: model) {
            environment.paste.clearTarget()
        }
        quickPaste = panel

        environment.onQuickPasteHotKey = { panel.toggle() }
        environment.onRecentSlotHotKey = { slot in
            Task { await environment.pasteRecentSlot(slot) }
        }
        environment.registerHotKeys()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(
                model: LibraryViewModel(store: environment.store),
                environment: environment)
                .frame(minWidth: 760, minHeight: 460)
                .task {
                    await environment.start()
                    installQuickPaste()
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("ClipRoid", systemImage: "doc.on.clipboard") {
            Button("Quick Paste") { quickPaste?.show() }
                .keyboardShortcut("v", modifiers: [.control, .command])
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

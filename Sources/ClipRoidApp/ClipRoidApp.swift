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

    /// Reopening from the Dock or Spotlight brings the window back. Returning true lets AppKit
    /// restore or recreate it, which is what makes the Dock icon work where a bare `activate`
    /// does not.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Diagnostics.log("Reopen requested (hasVisibleWindows: \(hasVisibleWindows))")
        return true
    }
}

@main
struct ClipRoidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var quickPaste: QuickPastePanel?
    @State private var shelf: ShelfPanel?
    /// Mirrors the shelf's visibility for the menu.
    ///
    /// Reading `shelf?.isVisible` directly did not work: it is not observable, so the menu item's
    /// label never refreshed. It kept reading "Hide Shelf" after hiding, and choosing it hid an
    /// already-hidden shelf — leaving no way to bring it back.
    @State private var isShelfShown = true
    @Environment(\.openWindow) private var openWindow

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

    @MainActor
    private func installShelf() {
        guard shelf == nil else { return }
        let model = ShelfViewModel(
            store: environment.store, coordinator: environment.paste,
            settings: environment.settings, enrichment: environment.enrichment,
            editor: environment.externalEditor)
        model.openLibrary = { NSApplication.shared.activate(ignoringOtherApps: true) }
        let panel = ShelfPanel(model: model, settings: environment.settings)
        shelf = panel
        panel.show()
        Diagnostics.log("Shelf shown at \(model.position.rawValue)")
    }

    static let libraryWindowID = "library"

    /// Brings the Library back, creating it if the user closed it.
    ///
    /// `NSApplication.activate` alone only raises windows that still exist. Once the Library had
    /// been closed, "Open ClipRoid" activated an app with no window and appeared to do nothing —
    /// while clicking the Dock icon worked, because AppKit's reopen handler creates one.
    @MainActor
    private func openLibraryWindow() {
        Diagnostics.log("Open ClipRoid chosen from the menu bar")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let existing = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue.contains(Self.libraryWindowID) == true
                || $0.title == "ClipRoid"
        }), existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: Self.libraryWindowID)
    }

    var body: some Scene {
        WindowGroup(id: Self.libraryWindowID) {
            LibraryView(store: environment.store, environment: environment)
                .frame(minWidth: 760, minHeight: 460)
                .task {
                    await environment.start()
                    installQuickPaste()
                    installShelf()
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(
                settings: environment.settings,
                rulesModel: RulesViewModel(
                    store: environment.store, service: environment.smartFilters),
                onShelfChange: {
                    shelf?.applySettings()
                    Task { await environment.applyRetentionSettings() }
                },
                onShortcutChange: {
                    Task { await environment.applyShortcutSettings() }
                },
                onPasteChange: {
                    environment.applyPasteSettings()
                    Task { await environment.applyLinkPreviewSettings() }
                })
        }

        MenuBarExtra("ClipRoid", systemImage: "doc.on.clipboard") {
            Button("Quick Paste") { quickPaste?.show() }
                .keyboardShortcut("v", modifiers: [.control, .command])

            Button(isShelfShown ? "Hide Shelf" : "Show Shelf") {
                if isShelfShown {
                    shelf?.hide()
                } else {
                    shelf?.show()
                }
                isShelfShown.toggle()
            }

            Button("Open ClipRoid") { openLibraryWindow() }
                .keyboardShortcut("o")
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

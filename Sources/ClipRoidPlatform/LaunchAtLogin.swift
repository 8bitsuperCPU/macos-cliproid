import Foundation
import ServiceManagement
import ClipRoidCore

/// Launch at login (spec §4.19).
///
/// Guarded on a bundle identifier being present: a bare `swift run` executable has no Info.plist,
/// `SMAppService` has nothing to register, and the call throws. Same guard and same reason as
/// nyx's SettingsStore.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public static func set(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Diagnostics.log("Launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}

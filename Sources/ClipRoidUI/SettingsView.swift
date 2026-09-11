import SwiftUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidPlatform

/// Preferences (spec §4.19). Covers what exists so far; grows with each milestone.
public struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var onShelfChange: @MainActor () -> Void

    public init(settings: SettingsStore, onShelfChange: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.onShelfChange = onShelfChange
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shelf.tabItem { Label("Shelf", systemImage: "rectangle.topthird.inset.filled") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    private var general: some View {
        Form {
            Toggle("Launch ClipRoid at login", isOn: $settings.launchAtLogin)

            Section {
                Toggle("Paste automatically after choosing a clip", isOn: $settings.autoPasteEnabled)
                // Stating plainly what the permission is for, and that the app still works without
                // it, is the honest version of asking (spec §9).
                if !PasteDeliverer.isAccessibilityGranted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Automatic pasting needs Accessibility permission.")
                                .font(.caption)
                            Text("Without it ClipRoid still copies your clip to the clipboard — you press ⌘V yourself.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Grant Accessibility…") { PasteDeliverer.requestAccessibility() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("Capture") {
                Toggle("Images and screenshots", isOn: $settings.captureImages)
                Toggle("Files", isOn: $settings.captureFiles)
            }

            Section("History") {
                Picker("Keep at most", selection: $settings.maxClipCount) {
                    Text("1,000 clips").tag(1_000)
                    Text("10,000 clips").tag(10_000)
                    Text("50,000 clips").tag(50_000)
                    Text("No limit").tag(0)
                }
                Picker("Delete clips older than", selection: $settings.maxClipAgeDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Never").tag(0)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shelf: some View {
        Form {
            Picker("Position", selection: $settings.shelfPosition) {
                ForEach(ShelfPositionSetting.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .onChange(of: settings.shelfPosition) { _, _ in onShelfChange() }

            Stepper("Show \(settings.shelfItemCount) recent clips",
                    value: $settings.shelfItemCount, in: 5...20)
                .onChange(of: settings.shelfItemCount) { _, _ in onShelfChange() }

            Section {
                Text("The shelf sits just below the menu bar. It stays out of the way and never takes keyboard focus — click an item to paste it, or drag it into any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Toggle("Detect passwords, keys and tokens", isOn: $settings.sensitiveDetectionEnabled)
            Toggle("Keep detected secrets off the shelf", isOn: $settings.hideSecretsFromShelf)
                .disabled(!settings.sensitiveDetectionEnabled)

            Section {
                Text("Detection is a local guess, not a guarantee. It looks for private keys, API tokens and card numbers, and deliberately ignores ordinary words like \"password\" so the warning stays meaningful.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Never capture from") {
                if settings.ignoredBundleIds.isEmpty {
                    Text("No apps ignored").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(settings.ignoredBundleIds, id: \.self) { bundleId in
                        HStack {
                            AppIcon(bundleId: bundleId, side: 14)
                            Text(bundleId).font(.caption)
                            Spacer()
                            Button("Remove") {
                                settings.ignoredBundleIds.removeAll { $0 == bundleId }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                Text("ClipRoid stores everything on this Mac and makes no network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

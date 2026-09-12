import SwiftUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidPlatform

/// Preferences (spec §4.19). Covers what exists so far; grows with each milestone.
public struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var onShelfChange: @MainActor () -> Void
    var onShortcutChange: @MainActor () -> Void
    @State private var rulesModel: RulesViewModel

    public init(
        settings: SettingsStore,
        rulesModel: RulesViewModel,
        onShelfChange: @escaping @MainActor () -> Void,
        onShortcutChange: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        _rulesModel = State(initialValue: rulesModel)
        self.onShelfChange = onShelfChange
        self.onShortcutChange = onShortcutChange
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shelf.tabItem { Label("Shelf", systemImage: "rectangle.topthird.inset.filled") }
            RulesView(model: rulesModel).tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "text.cursor") }
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

            Toggle("Collapse to a small bar until I point at it", isOn: $settings.shelfAutoHide)
                .onChange(of: settings.shelfAutoHide) { _, _ in onShelfChange() }

            Section("Size") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: $settings.shelfThickness,
                        in: 44...170, step: 2
                    ) {
                        Text("Size")
                    } minimumValueLabel: {
                        Image(systemName: "rectangle.compress.vertical").font(.caption2)
                    } maximumValueLabel: {
                        Image(systemName: "rectangle.expand.vertical").font(.caption2)
                    }
                    .onChange(of: settings.shelfThickness) { _, _ in onShelfChange() }

                    Text("\(Int(settings.shelfThickness))pt tall — taller cards show more of each clip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Background") {
                Picker("Style", selection: $settings.shelfBackground) {
                    ForEach(ShelfBackground.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: settings.shelfBackground) { _, _ in onShelfChange() }

                if settings.shelfBackground == .custom {
                    ColorPicker("Colour", selection: Binding(
                        get: { Color(hex: settings.shelfTintHex) ?? .black },
                        set: { settings.shelfTintHex = $0.hexString; onShelfChange() }
                    ), supportsOpacity: false)

                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $settings.shelfOpacity, in: 0.2...1.0) {
                            Text("Opacity")
                        }
                        .onChange(of: settings.shelfOpacity) { _, _ in onShelfChange() }
                        Text("\(Int(settings.shelfOpacity * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("The shelf sits just below the menu bar. It never takes keyboard focus — click a card to paste it, or drag it into any app. Card colours stay the same whatever background you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Inline shortcuts, and the keystroke observation they require.
    ///
    /// This pane is written to be read before the toggle is flipped, not after. A clipboard
    /// manager asking to watch your keystrokes has to say exactly what it does with them, in
    /// plain words, or the honest answer from a careful user is no — and it should be.
    private var shortcuts: some View {
        Form {
            Toggle("Expand shortcuts as I type", isOn: $settings.inlineShortcutsEnabled)
                .onChange(of: settings.inlineShortcutsEnabled) { _, _ in onShortcutChange() }

            Section("What this means") {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("ClipRoid watches for typed characters so it can recognise a shortcut like \(settings.shortcutPrefix)welcome.")
                    } icon: { Image(systemName: "keyboard") }

                    Label {
                        Text("Nothing is kept. Characters are only held while a shortcut is part-typed, never written to disk, and discarded the moment you type anything else or switch apps.")
                    } icon: { Image(systemName: "trash") }

                    Label {
                        Text("Turning this off removes the keyboard observer entirely — it is not left running and ignored.")
                    } icon: { Image(systemName: "xmark.circle") }

                    Label {
                        Text("This needs Accessibility permission, and works only while ClipRoid is running.")
                    } icon: { Image(systemName: "lock") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if settings.inlineShortcutsEnabled {
                Section {
                    Picker("Expand", selection: $settings.shortcutTrigger) {
                        ForEach(ShortcutTrigger.allCases, id: \.self) { trigger in
                            Text(trigger.displayName).tag(trigger)
                        }
                    }
                    .onChange(of: settings.shortcutTrigger) { _, _ in onShortcutChange() }

                    TextField("Prefix character", text: $settings.shortcutPrefix)
                        .frame(width: 60)
                        .onChange(of: settings.shortcutPrefix) { _, new in
                            // One character, and never a letter or digit — a prefix that can
                            // appear mid-word would fire constantly during ordinary typing.
                            let filtered = new.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
                            settings.shortcutPrefix = String(filtered.prefix(1))
                            onShortcutChange()
                        }
                }
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

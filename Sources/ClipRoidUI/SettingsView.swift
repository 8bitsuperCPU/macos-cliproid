import SwiftUI
import UniformTypeIdentifiers
import ClipRoidCore
import ClipRoidKit
import ClipRoidPlatform
import ClipRoidStore

/// Preferences (spec §4.19). Covers what exists so far; grows with each milestone.
public struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let store: ClipStore
    var onShelfChange: @MainActor () -> Void
    var onShortcutChange: @MainActor () -> Void
    var onPasteChange: @MainActor () -> Void
    var onCaptureChange: @MainActor () -> Void
    @State private var rulesModel: RulesViewModel
    /// How many clips "Clear History" is about to delete. Non-nil presents the confirmation.
    @State private var pendingClearCount: Int?
    @State private var clearError: String?

    public init(
        settings: SettingsStore,
        store: ClipStore,
        rulesModel: RulesViewModel,
        onShelfChange: @escaping @MainActor () -> Void,
        onShortcutChange: @escaping @MainActor () -> Void,
        onPasteChange: @escaping @MainActor () -> Void,
        onCaptureChange: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        self.store = store
        _rulesModel = State(initialValue: rulesModel)
        self.onShelfChange = onShelfChange
        self.onShortcutChange = onShortcutChange
        self.onPasteChange = onPasteChange
        self.onCaptureChange = onCaptureChange
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shelf.tabItem { Label("Shelf", systemImage: "rectangle.topthird.inset.filled") }
            RulesView(model: rulesModel).tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            // Built, tested and switched off — see FeatureFlags.inlineShortcuts. The pane below
            // is left intact rather than deleted so turning the feature back on is one flag.
            if FeatureFlags.inlineShortcuts {
                shortcuts.tabItem { Label("Shortcuts", systemImage: "text.cursor") }
            }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            AboutView(settings: settings).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500)
        .padding(.vertical, 8)
    }

    private var general: some View {
        Form {
            Toggle("Launch ClipDroid at login", isOn: $settings.launchAtLogin)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Ask before quitting", isOn: $settings.confirmOnQuit)
                Text("Cmd+Q offers to close the window instead, which leaves capture and the Ctrl+Cmd+V shortcut running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // A titled section, not an anonymous one. Unlabelled it read as a continuation of
            // the block above, and the one control people go looking for was the hardest to find.
            Section("Pasting") {
                Toggle("Paste automatically after choosing a clip", isOn: $settings.autoPasteEnabled)
                    .onChange(of: settings.autoPasteEnabled) { _, _ in onPasteChange() }
                if !settings.autoPasteEnabled {
                    Text("Clips are copied to the clipboard and you press ⌘V yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Stating plainly what the permission is for, and that the app still works without
                // it, is the honest version of asking (spec §9).
                if !PasteDeliverer.isAccessibilityGranted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Automatic pasting needs Accessibility permission.")
                                .font(.caption)
                            Text("Without it ClipDroid still copies your clip to the clipboard — you press ⌘V yourself.")
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

            Section("Link previews") {
                Toggle("Fetch a title and image for copied links",
                       isOn: $settings.fetchLinkPreviews)
                    .onChange(of: settings.fetchLinkPreviews) { _, _ in onPasteChange() }

                // Said plainly, because this is the one thing in the app that reaches the network
                // and the rest of the product promises it never does.
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("This is the only time ClipDroid contacts the internet. Everything else stays on this Mac.")
                    } icon: { Image(systemName: "network") }

                    Label {
                        Text("Copying a link asks that website for its title and preview image — which tells the site that someone copied its link just then, from your IP address.")
                    } icon: { Image(systemName: "eye") }

                    Label {
                        Text("Requests carry no cookies, so you are not identified as a logged-in user.")
                    } icon: { Image(systemName: "lock") }

                    if !settings.fetchLinkPreviews {
                        Label {
                            Text("With this off, link clips still show the site's domain — that is worked out locally.")
                        } icon: { Image(systemName: "checkmark.circle") }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 2) {
                    Button("Clear History…", role: .destructive) {
                        Task { pendingClearCount = (try? await store.count()) ?? 0 }
                    }
                    Text("Deletes every clip, including pinned and favourite ones.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Counted when asked rather than kept live: the number is only needed at the moment of
        // confirming, and "Delete 1,204 clips" is what makes an irreversible action legible.
        .confirmationDialog(
            pendingClearCount == 1 ? "Delete 1 clip?" : "Delete all \(pendingClearCount ?? 0) clips?",
            isPresented: Binding(get: { (pendingClearCount ?? 0) > 0 },
                                 set: { if !$0 { pendingClearCount = nil } })
        ) {
            Button("Delete All", role: .destructive) {
                Task {
                    do { try await store.deleteAll() }
                    catch { clearError = error.localizedDescription }
                }
            }
        } message: {
            Text("Pinned and favourite clips are deleted too. This can't be undone.")
        }
        .alert("Couldn't clear history", isPresented: Binding(
            get: { clearError != nil }, set: { if !$0 { clearError = nil } })
        ) {} message: {
            Text(clearError ?? "")
        }
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

            if settings.shelfAutoHide {
                Section("Collapsed bar") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $settings.collapsedThickness, in: 8...40, step: 1) {
                            Text("Thickness")
                        }
                        .onChange(of: settings.collapsedThickness) { _, _ in onShelfChange() }
                        Text("\(Int(settings.collapsedThickness))pt thick")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $settings.collapsedLength, in: 60...900, step: 10) {
                            Text("Width")
                        }
                        .onChange(of: settings.collapsedLength) { _, _ in onShelfChange() }
                        Text("\(Int(settings.collapsedLength))pt wide")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Toggle("Show the shelf briefly at launch", isOn: $settings.peekShelfOnLaunch)
                    Toggle("Animated rainbow", isOn: $settings.collapsedRainbow)
                        .onChange(of: settings.collapsedRainbow) { _, _ in onShelfChange() }
                    if settings.collapsedRainbow {
                        Text("The bar is on screen whenever the shelf is collapsed, so this repaints continuously. It is capped at 30fps, but it will still use a little more power than a static bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Size") {
                VStack(alignment: .leading, spacing: 4) {
                    // The range MUST track SettingsStore.clampThickness. When these disagreed
                    // the slider looked broken: the clamp floor sat two thirds of the way along
                    // the track, so most of its travel resolved to the same value and dragging
                    // did nothing, while the top of the range was unreachable.
                    Slider(
                        value: $settings.shelfThickness,
                        in: SettingsStore.thicknessRange, step: 2
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

            Section("Hover preview") {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $settings.previewHeightFraction, in: 0.25...0.85, step: 0.05) {
                        Text("Height")
                    }
                    Text("\(Int(settings.previewHeightFraction * 100))% of the screen height")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $settings.previewCloseDelay, in: 1...10, step: 0.5) {
                        Text("Stays open for")
                    }
                    Text(String(format: "%.1f seconds after the pointer leaves", settings.previewCloseDelay))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Hovering a card opens a preview. Move onto it within that time and click to keep it open — it then stays, with tools, until you close it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Background") {
                Picker("Style", selection: $settings.shelfBackground) {
                    ForEach(ShelfBackground.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: settings.shelfBackground) { _, _ in onShelfChange() }

                Picker("Text", selection: $settings.shelfTextStyle) {
                    ForEach(ShelfTextStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: settings.shelfTextStyle) { _, _ in onShelfChange() }

                if settings.shelfTextStyle == .automatic {
                    Text("Chosen from the background's brightness, so a pale shelf gets dark text rather than invisible white text.")
                        .font(.caption).foregroundStyle(.secondary)
                }

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
                        Text("ClipDroid watches for typed characters so it can recognise a shortcut like \(settings.shortcutPrefix)welcome.")
                    } icon: { Image(systemName: "keyboard") }

                    Label {
                        Text("Nothing is kept. Characters are only held while a shortcut is part-typed, never written to disk, and discarded the moment you type anything else or switch apps.")
                    } icon: { Image(systemName: "trash") }

                    Label {
                        Text("Turning this off removes the keyboard observer entirely — it is not left running and ignored.")
                    } icon: { Image(systemName: "xmark.circle") }

                    Label {
                        Text("This needs Accessibility permission, and works only while ClipDroid is running.")
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.appName(forBundleId: bundleId) ?? bundleId)
                                Text(bundleId).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                settings.ignoredBundleIds.removeAll { $0 == bundleId }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Button("Add App…") { chooseAppsToIgnore() }
            }
            .onChange(of: settings.ignoredBundleIds) { _, _ in onCaptureChange() }

            Section {
                Text("ClipDroid stores everything on this Mac and makes no network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Lets the user pick apps in Finder to add to "Never capture from".
    ///
    /// The list stores bundle identifiers, not paths, because that is what the capture side sees
    /// for the frontmost app — and it survives the app being moved or updated.
    private func chooseAppsToIgnore() {
        let panel = NSOpenPanel()
        panel.title = "Never Capture From"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }

        let chosen = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        for bundleId in chosen where !settings.ignoredBundleIds.contains(bundleId) {
            settings.ignoredBundleIds.append(bundleId)
        }
    }

    private static func appName(forBundleId bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

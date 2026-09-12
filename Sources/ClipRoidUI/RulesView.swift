import SwiftUI
import ClipRoidCore
import ClipRoidKit
import ClipRoidStore

/// Smart filter rule management (spec §4.2).
@MainActor
@Observable
public final class RulesViewModel {
    public private(set) var rules: [SmartFilterRule] = []
    public private(set) var categories: [ClipCategory] = []
    public private(set) var isReapplying = false
    public private(set) var reapplyMessage: String?

    private let store: ClipStore
    private let service: SmartFilterService

    public init(store: ClipStore, service: SmartFilterService) {
        self.store = store
        self.service = service
    }

    public func load() async {
        rules = (try? await store.smartFilterRules()) ?? []
        categories = (try? await store.categories()) ?? []
    }

    public func save(_ rule: SmartFilterRule) async -> String? {
        if let error = SmartFilterEngine.validationError(for: rule) { return error }
        if rule.id == 0 {
            _ = try? await store.createRule(rule)
        } else {
            try? await store.updateRule(rule)
        }
        // Drop the cache so the next captured clip is filed by the new rule, not the old one.
        await service.invalidateRules()
        await load()
        return nil
    }

    public func delete(_ rule: SmartFilterRule) async {
        try? await store.deleteRule(id: rule.id)
        await service.invalidateRules()
        await load()
    }

    public func toggle(_ rule: SmartFilterRule) async {
        var updated = rule
        updated.enabled.toggle()
        try? await store.updateRule(updated)
        await service.invalidateRules()
        await load()
    }

    /// Applies every rule across the whole history (spec §4.2).
    public func reapplyToAll() async {
        isReapplying = true
        reapplyMessage = "Working…"
        defer { isReapplying = false }
        let assigned = await service.reapplyToAll()
        reapplyMessage = assigned == 0
            ? "No clips matched."
            : "Filed \(assigned) clip\(assigned == 1 ? "" : "s")."
    }
}

public struct RulesView: View {
    @Bindable var model: RulesViewModel
    @State private var editing: SmartFilterRule?

    public init(model: RulesViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                if model.rules.isEmpty {
                    Text("No rules yet. A rule files clips into a category automatically — for example, everything copied from Figma into Design Assets.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.rules) { rule in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { _ in Task { await model.toggle(rule) } }))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.name)
                                Text(describe(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { editing = rule }.controlSize(.small)
                            Button("Delete", role: .destructive) {
                                Task { await model.delete(rule) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Button("New Rule…", systemImage: "plus") {
                    editing = SmartFilterRule(
                        id: 0, name: "", categoryId: model.categories.first?.id ?? 0)
                }
                .disabled(model.categories.isEmpty)
                if model.categories.isEmpty {
                    Text("Create a category first — a rule needs somewhere to file clips.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Rules")
            }

            Section {
                HStack {
                    Button("Apply rules to existing clips") {
                        Task { await model.reapplyToAll() }
                    }
                    .disabled(model.isReapplying || model.rules.isEmpty)
                    if model.isReapplying { ProgressView().controlSize(.small) }
                    if let message = model.reapplyMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Rules normally apply to new clips as they are copied. This applies them to everything already in your history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, categories: model.categories) { edited in
                await model.save(edited)
            } onClose: {
                editing = nil
            }
        }
    }

    private func describe(_ rule: SmartFilterRule) -> String {
        var parts: [String] = []
        if let type = rule.contentType { parts.append(type.displayName) }
        if let app = rule.sourceAppBundleId, !app.isEmpty { parts.append("from \(app)") }
        if let pattern = rule.textPattern, !pattern.isEmpty {
            parts.append(rule.isRegex ? "matching /\(pattern)/" : "containing “\(pattern)”")
        }
        let category = model.categories.first { $0.id == rule.categoryId }?.name ?? "?"
        return parts.isEmpty ? "no conditions → \(category)" : parts.joined(separator: ", ") + " → \(category)"
    }
}

struct RuleEditor: View {
    @State var rule: SmartFilterRule
    let categories: [ClipCategory]
    let onSave: (SmartFilterRule) async -> String?
    let onClose: () -> Void

    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(rule.id == 0 ? "New Rule" : "Edit Rule")
                .font(.headline).padding()
            Divider()
            Form {
                TextField("Name", text: $rule.name)

                Picker("File into", selection: $rule.categoryId) {
                    ForEach(categories) { Text($0.name).tag($0.id) }
                }

                Section("When a clip matches all of these") {
                    Picker("Type", selection: Binding(
                        get: { rule.contentType },
                        set: { rule.contentType = $0 })) {
                        Text("Any").tag(ClipContentType?.none)
                        ForEach(ClipContentType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(ClipContentType?.some(type))
                        }
                    }
                    TextField("From app", text: Binding(
                        get: { rule.sourceAppBundleId ?? "" },
                        set: { rule.sourceAppBundleId = $0.isEmpty ? nil : $0 }))
                        .help("An app name or bundle id — “Figma” works as well as “com.figma.Desktop”")
                    TextField("Text contains", text: Binding(
                        get: { rule.textPattern ?? "" },
                        set: { rule.textPattern = $0.isEmpty ? nil : $0 }))
                    Toggle("Treat as a regular expression", isOn: $rule.isRegex)
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save") {
                    Task {
                        error = await onSave(rule)
                        if error == nil { onClose() }
                    }
                }
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 440)
    }
}


import SwiftUI

/// Editor for a single subscription rule. Takes a `rule` copy so edits stay
/// local until the caller persists via `onCommit`. The parent store
/// handles persistence in one shot when the user saves the page.
struct SubscriptionRuleEditorView: View {
    let taxonomy: BulletinTaxonomyStore
    let onCommit: (BulletinAPI.SubscriptionRule) -> Void
    let onDelete: (() -> Void)?

    @State private var name: String
    @State private var orgs: Set<String>
    @State private var tags: Set<String>
    @State private var mode: BulletinAPI.SubscriptionMode
    @State private var enabled: Bool

    @Environment(\.dismiss) private var dismiss

    private let original: BulletinAPI.SubscriptionRule

    init(
        rule: BulletinAPI.SubscriptionRule,
        taxonomy: BulletinTaxonomyStore,
        onCommit: @escaping (BulletinAPI.SubscriptionRule) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.original = rule
        self.taxonomy = taxonomy
        self.onCommit = onCommit
        self.onDelete = onDelete
        self._name = State(initialValue: rule.name ?? "")
        self._orgs = State(initialValue: Set(rule.orgs))
        self._tags = State(initialValue: Set(rule.tags))
        self._mode = State(initialValue: rule.mode)
        self._enabled = State(initialValue: rule.enabled)
    }

    var body: some View {
        Form {
            Section("名稱") {
                TextField("例如：教務 + 獎學金", text: $name)
            }

            Section("處室") {
                NavigationLink {
                    BulletinTaxonomyPickerView(
                        title: "處室",
                        options: orgOptions,
                        selected: $orgs
                    )
                } label: {
                    HStack {
                        Text(orgs.isEmpty ? "全部處室" : "已選 \(orgs.count) 個")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(summaryLabels(orgs, lookup: taxonomy.orgLabel(for:)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Section("類別") {
                NavigationLink {
                    BulletinTaxonomyPickerView(
                        title: "類別",
                        options: tagOptions,
                        selected: $tags
                    )
                } label: {
                    HStack {
                        Text(tags.isEmpty ? "全部類別" : "已選 \(tags.count) 個")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(summaryLabels(tags, lookup: taxonomy.tagLabel(for:)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Section {
                Picker("模式", selection: $mode) {
                    ForEach(BulletinAPI.SubscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(modeFooter)
                    .font(.caption)
            }

            Section {
                Toggle("啟用此規則", isOn: $enabled)
            }

            if let onDelete {
                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("刪除規則", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(original.id == nil ? "新增規則" : "編輯規則")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    commit()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Helpers

    private var orgOptions: [(id: String, label: String)] {
        taxonomy.state.taxonomy?.orgs.map { (id: $0.rawId, label: $0.label) } ?? []
    }

    private var tagOptions: [(id: String, label: String)] {
        taxonomy.state.taxonomy?.tags.map { (id: $0.rawId, label: $0.label) } ?? []
    }

    private var modeFooter: String {
        switch mode {
        case .and: return "同時符合所選的處室與類別才會推播。"
        case .or: return "符合任一處室或類別就會推播。"
        }
    }

    private func summaryLabels(_ ids: Set<String>, lookup: (String) -> String) -> String {
        let labels = ids.map(lookup).sorted()
        return labels.joined(separator: "、")
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let sanitizedName = trimmed.isEmpty ? nil : trimmed
        let updated = BulletinAPI.SubscriptionRule(
            id: original.id,
            clientId: original.clientId,
            name: sanitizedName,
            orgs: Array(orgs).sorted(),
            tags: Array(tags).sorted(),
            mode: mode,
            enabled: enabled
        )
        onCommit(updated)
    }
}

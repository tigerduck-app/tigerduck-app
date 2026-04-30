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
            Section(String(localized: "bulletin_rule_editor_name_section")) {
                TextField(String(localized: "bulletin_rule_editor_name_placeholder"), text: $name)
            }

            Section(String(localized: "bulletin_filter_dept")) {
                NavigationLink {
                    BulletinTaxonomyPickerView(
                        title: String(localized: "bulletin_filter_dept"),
                        options: orgOptions,
                        selected: $orgs
                    )
                } label: {
                    HStack {
                        Text(orgs.isEmpty
                            ? String(localized: "bulletin_rule_all_orgs")
                            : String(format: String(localized: "bulletin_rule_editor_selected_count"), orgs.count))
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

            Section(String(localized: "bulletin_filter_tag")) {
                NavigationLink {
                    BulletinTaxonomyPickerView(
                        title: String(localized: "bulletin_filter_tag"),
                        options: tagOptions,
                        selected: $tags
                    )
                } label: {
                    HStack {
                        Text(tags.isEmpty
                            ? String(localized: "bulletin_rule_all_tags")
                            : String(format: String(localized: "bulletin_rule_editor_selected_count"), tags.count))
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
                Picker(String(localized: "bulletin_rule_editor_mode_section"), selection: $mode) {
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
                Toggle(String(localized: "bulletin_rule_editor_enable_toggle"), isOn: $enabled)
            }

            if let onDelete {
                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label(String(localized: "bulletin_rule_delete_action"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(original.id == nil
            ? String(localized: "bulletin_rule_add_title")
            : String(localized: "bulletin_rule_edit_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "action_done")) {
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
        case .and: return String(localized: "bulletin_rule_editor_mode_and_footer")
        case .or: return String(localized: "bulletin_rule_editor_mode_or_footer")
        }
    }

    private func summaryLabels(_ ids: Set<String>, lookup: (String) -> String) -> String {
        let labels = ids.map(lookup).sorted()
        return labels.joined(separator: String(localized: "bulletin_rule_filter_separator"))
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

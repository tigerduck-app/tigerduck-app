import SwiftUI

/// The bulletin subscription rules, and the offer of the default rules while there are none.
struct BulletinRulesSections: View {
    let store: BulletinSubscriptionsStore
    let taxonomy: BulletinTaxonomyStore
    @Binding var editingClientId: UUID?
    @Binding var draftRule: BulletinAPI.SubscriptionRule?

    var body: some View {
        rulesSection
        if store.loadState == .loaded, store.pending.isEmpty {
            defaultRuleBanner
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            switch store.loadState {
            case .idle, .loading:
                HStack(spacing: TigerDuckTheme.Spacing.xs) {
                    ProgressView()
                    Text(String(localized: "bulletin_rules_load_loading")).foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text(String(localized: "bulletin_rules_load_failed")).foregroundStyle(.primary)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "action_retry")) {
                        Task { await store.load() }
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                ForEach(store.pending, id: \.clientId) { rule in
                    Button {
                        editingClientId = rule.clientId
                    } label: {
                        ruleRow(rule)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteRules)

                Button {
                    let draft = store.makeNewRule()
                    draftRule = draft
                    editingClientId = draft.clientId
                } label: {
                    Label(String(localized: "bulletin_rule_add_action"), systemImage: "plus")
                }
            }
        } header: {
            Text(String(localized: "bulletin_rules_header"))
        } footer: {
            Text(String(localized: "bulletin_rules_footer"))
        }
    }

    private var defaultRuleBanner: some View {
        Section {
            Button {
                if let tax = taxonomy.state.taxonomy {
                    store.seedDefault(from: tax)
                    Task { await store.save() }
                }
            } label: {
                Label(String(localized: "bulletin_apply_default_rules_action"), systemImage: "wand.and.stars")
            }
        } footer: {
            Text(String(localized: "bulletin_default_rules_footer"))
        }
    }

    private func ruleRow(_ rule: BulletinAPI.SubscriptionRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name?.nilIfEmpty ?? defaultRuleTitle(rule))
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if !rule.enabled {
                    Text(String(localized: "bulletin_rule_disabled_badge"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            Text(ruleSubtitle(rule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
    }

    private func deleteRules(at offsets: IndexSet) {
        for index in offsets {
            let rule = store.pending[index]
            store.removeRule(clientId: rule.clientId)
        }
        Task { await store.save() }
    }

    private func defaultRuleTitle(_ rule: BulletinAPI.SubscriptionRule) -> String {
        if rule.orgs.isEmpty, rule.tags.isEmpty { return String(localized: "bulletin_rule_all_title") }
        if !rule.orgs.isEmpty, !rule.tags.isEmpty {
            return String(format: String(localized: "bulletin_rule_dept_and_tag_title"), rule.mode.displayName)
        }
        if !rule.orgs.isEmpty { return String(localized: "bulletin_rule_dept_only_title") }
        return String(localized: "bulletin_rule_tag_only_title")
    }

    private func ruleSubtitle(_ rule: BulletinAPI.SubscriptionRule) -> String {
        let separator = String(localized: "bulletin_rule_filter_separator")
        let orgText = rule.orgs.isEmpty
            ? String(localized: "bulletin_rule_all_depts")
            : String(localized: "bulletin_rule_dept_prefix") + rule.orgs.map { taxonomy.orgLabel(for: $0) }.joined(separator: separator)
        let tagText = rule.tags.isEmpty
            ? String(localized: "bulletin_rule_all_tags")
            : String(localized: "bulletin_rule_tags_prefix") + rule.tags.map { taxonomy.tagLabel(for: $0) }.joined(separator: separator)
        let joiner = rule.mode == .and
            ? String(localized: "bulletin_rule_join_and")
            : String(localized: "bulletin_rule_join_or")
        return orgText + joiner + tagText
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

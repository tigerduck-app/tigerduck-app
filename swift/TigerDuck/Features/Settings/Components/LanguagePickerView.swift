import SwiftUI

struct LanguagePickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct LanguageRow: Identifiable {
        let id: String  // BCP-47 tag
        let nativeName: String
        let localizedName: String
    }

    private var allRows: [LanguageRow] {
        let uiLocale = Locale.current
        return LanguageManager.supportedLocaleTags().map { tag in
            let locale = Locale(identifier: tag)
            let native = locale.localizedString(forIdentifier: tag) ?? tag
            let localized = uiLocale.localizedString(forIdentifier: tag) ?? tag
            return LanguageRow(id: tag, nativeName: native, localizedName: localized)
        }.sorted { $0.nativeName.localizedCompare($1.nativeName) == .orderedAscending }
    }

    private var filteredRows: [LanguageRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allRows }
        return allRows.filter {
            $0.id.lowercased().contains(q) ||
            $0.nativeName.lowercased().contains(q) ||
            $0.localizedName.lowercased().contains(q)
        }
    }

    var body: some View {
        @Bindable var appState = appState
        List {
            Section {
                Text(String(localized: "language_picker_ai_translation_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                languageRow(
                    tag: LanguageManager.system,
                    title: String(localized: "settings_language_follow_system"),
                    subtitle: nil
                )
            }

            Section {
                ForEach(filteredRows) { row in
                    languageRow(
                        tag: row.id,
                        title: row.nativeName,
                        subtitle: row.nativeName != row.localizedName ? row.localizedName : nil
                    )
                }
            }
        }
        .searchable(text: $query, prompt: String(localized: "action_search"))
        .navigationTitle(String(localized: "settings_language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func languageRow(tag: String, title: String, subtitle: String?) -> some View {
        Button {
            appState.appLanguage = tag
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if appState.appLanguage == tag {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
        }
    }
}

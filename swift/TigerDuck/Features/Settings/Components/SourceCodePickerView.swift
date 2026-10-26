import SwiftUI

struct SourceCodePickerView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                repoRow(entry: .organization)
            }

            Section(String(localized: "source_code_picker_section_repositories")) {
                ForEach(SourceRepository.all) { entry in
                    repoRow(entry: entry)
                }
            }
        }
        .navigationTitle(String(localized: "settings_view_source_code"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func repoRow(entry: SourceRepository) -> some View {
        Button {
            openURL(entry.url)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.slug)
                            .foregroundStyle(.primary)
                        if entry.isCurrent {
                            Text(String(localized: "source_code_picker_current_app_badge"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(LocalizedStringKey(entry.descriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

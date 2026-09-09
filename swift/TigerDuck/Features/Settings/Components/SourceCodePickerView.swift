import SwiftUI
import UIKit

struct SourceCodePickerView: View {
    @Environment(AppState.self) private var appState

    private struct IdentifiableURL: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @State private var inAppURL: IdentifiableURL?

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
        .sheet(item: $inAppURL) { wrapped in
            InAppBrowserView(url: wrapped.url)
                .ignoresSafeArea()
        }
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

    private func openURL(_ url: URL) {
        if appState.browserPreference == .inApp {
            inAppURL = IdentifiableURL(url: url)
        } else {
            UIApplication.shared.open(url)
        }
    }
}

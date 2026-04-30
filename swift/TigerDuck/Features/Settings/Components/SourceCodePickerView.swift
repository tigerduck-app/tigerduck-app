import SwiftUI
import UIKit

struct SourceCodePickerView: View {
    @Environment(AppState.self) private var appState

    private struct RepoEntry {
        let slug: String
        let descriptionKey: String
        let url: URL
        let isCurrent: Bool
    }

    private struct IdentifiableURL: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @State private var inAppURL: IdentifiableURL?

    private let orgEntry = RepoEntry(
        slug: "tigerduck-app",
        descriptionKey: "source_code_picker_org_description",
        url: URL(string: "https://github.com/tigerduck-app")!,
        isCurrent: false
    )

    private let repoEntries: [RepoEntry] = [
        RepoEntry(
            slug: "tigerduck-app",
            descriptionKey: "source_code_picker_repo_apple_description",
            url: URL(string: "https://github.com/tigerduck-app/tigerduck-app")!,
            isCurrent: true
        ),
        RepoEntry(
            slug: "tigerduck-app-android",
            descriptionKey: "source_code_picker_repo_android_description",
            url: URL(string: "https://github.com/tigerduck-app/tigerduck-app-android")!,
            isCurrent: false
        ),
        RepoEntry(
            slug: "app-translation",
            descriptionKey: "source_code_picker_repo_translation_description",
            url: URL(string: "https://github.com/tigerduck-app/app-translation")!,
            isCurrent: false
        ),
        RepoEntry(
            slug: "name-abbr",
            descriptionKey: "source_code_picker_repo_name_abbr_description",
            url: URL(string: "https://github.com/tigerduck-app/name-abbr")!,
            isCurrent: false
        ),
        RepoEntry(
            slug: "tigerduck-web",
            descriptionKey: "source_code_picker_repo_web_description",
            url: URL(string: "https://github.com/tigerduck-app/tigerduck-web")!,
            isCurrent: false
        ),
    ]

    var body: some View {
        List {
            Section {
                repoRow(entry: orgEntry)
            }

            Section(String(localized: "source_code_picker_section_repositories")) {
                ForEach(repoEntries, id: \.slug) { entry in
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
    private func repoRow(entry: RepoEntry) -> some View {
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

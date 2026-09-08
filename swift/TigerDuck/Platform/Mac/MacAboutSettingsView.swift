#if os(macOS)
import SwiftUI

/// About tab — identity, the project links, and where the source lives.
/// One of the tabs assembled by `MacSettingsScene`.
///
/// The links are the same set the iPhone carries, minus its in-app
/// browser: on the Mac every one of them hands off to the default
/// browser, so every one of them is drawn as a link and says so.
struct MacAboutSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var isShowingRepositories = false

    var body: some View {
        Form {
            Section {
                identity
            }

            Section {
                linkRow("settings_check_server_status", url: AppURLs.serverStatus)
                linkRow("settings_official_website", url: AppURLs.website)
                linkRow("settings_feedback_bug_report", url: AppURLs.issues)
                linkRow("settings_privacy_policy", url: AppURLs.privacyPolicy)
                linkRow("settings_delete_account", url: AppURLs.deleteAccount)
                linkRow("settings_open_source_licenses", url: AppURLs.license)
            }

            // A disclosure rather than a second window: five repositories
            // is a list worth reading in place, and the Settings window is
            // fixed-size with no navigation stack to push onto.
            Section {
                DisclosureGroup(isExpanded: $isShowingRepositories) {
                    repoRow(.organization)
                    ForEach(SourceRepository.all) { repo in
                        repoRow(repo)
                    }
                } label: {
                    Text(String(localized: "settings_view_source_code"))
                }
            }

            Section {
                Text(String(localized: "desktop_about_copyright"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var identity: some View {
        VStack(spacing: 10) {
            // The app's own logo, not a generic mortarboard — this is the
            // one place in the app that answers "what am I looking at".
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(String(localized: "app_name"))
                .font(.title.bold())
            Text(String(format: String(localized: "desktop_about_version_value"), appVersion))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(localized: "desktop_about_subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Tinted rather than primary-coloured: these rows leave the app, and
    /// a plain-styled Button gives back the label's own colour, so without
    /// this they read as ordinary settings text that happens to have a
    /// glyph next to it. The tint is the user's accent colour, which the
    /// Settings scene sets on the whole window.
    private func linkRow(_ key: String.LocalizationValue, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(String(localized: key))
                    .foregroundStyle(.tint)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            // Without this the row is only hittable on the glyphs
            // themselves, since a plain-styled Button takes its label's
            // shape and the Spacer is not part of it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func repoRow(_ repo: SourceRepository) -> some View {
        Button {
            openURL(repo.url)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.slug)
                            .foregroundStyle(.tint)
                        if repo.isCurrent {
                            Text(String(localized: "source_code_picker_current_app_badge"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(LocalizedStringKey(repo.descriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
#endif

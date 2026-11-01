import SwiftUI

struct SettingsAboutSection: View {
    let sheets: SettingsSheetState

    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL

    private static let websiteURL = AppURLs.website

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (Build \(build))"
    }

    var body: some View {
        Section(String(localized: "settings_section_about")) {
            LabeledContent(String(localized: "settings_version"), value: appVersion)
            #if os(iOS)
            checkForUpdatesRow
            serverStatusRow
            whatsNewRow
            #endif
            Button {
                openURL(Self.websiteURL)
            } label: {
                HStack {
                    Text(String(localized: "settings_official_website"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink(String(localized: "settings_about_others")) {
                AboutOthersView()
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var checkForUpdatesRow: some View {
        Button {
            Task {
                await app.updateNotifyCoordinator.checkManually()
                let result = app.updateNotifyCoordinator.lastManualCheckResult
                if case .offered = result { return }
                if result != nil { sheets.showManualUpdateCheckResultAlert = true }
            }
        } label: {
            HStack {
                Text(String(localized: "settings_check_for_updates"))
                    .foregroundStyle(.primary)
                Spacer()
                if app.updateNotifyCoordinator.isCheckingForUpdate {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(app.updateNotifyCoordinator.isCheckingForUpdate)
    }

    private var serverStatusRow: some View {
        Button {
            openURL(AppURLs.serverStatus)
        } label: {
            HStack {
                Text(String(localized: "settings_check_server_status"))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whatsNewRow: some View {
        if app.updateNotifyCoordinator.hasWhatsNewContent(in: app) {
            Button {
                sheets.manualWhatsNewItem = app.updateNotifyCoordinator.latestWhatsNew(in: app)
            } label: {
                HStack {
                    Text(String(localized: "settings_whats_new"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif
}

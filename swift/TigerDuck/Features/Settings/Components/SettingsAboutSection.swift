import SwiftUI

struct SettingsAboutSection: View {
    let sheets: SettingsSheetState

    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    @Environment(\.openURL) private var openURL
    @Environment(\.settingsState) private var state

    private static let websiteURL = AppURLs.website

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (Build \(build))"
    }

    var body: some View {
        Section(String(localized: "settings_section_about")) {
            LabeledContent(SettingsRow.version.label, value: appVersion)
                .settingsRow(.version)
            #if os(iOS)
            checkForUpdatesRow
                .settingsRow(.checkForUpdates)
            serverStatusRow
                .settingsRow(.serverStatus)
            if SettingsRow.whatsNew.isShown(in: state) {
                whatsNewRow
                    .settingsRow(.whatsNew)
            }
            #endif
            Button {
                openURL(Self.websiteURL)
            } label: {
                HStack {
                    Text(SettingsRow.website.label)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsRow(.website)
            NavigationLink(SettingsRow.aboutOthers.label) {
                AboutOthersView()
            }
            .settingsRow(.aboutOthers)
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var checkForUpdatesRow: some View {
        Button {
            guard let app else { return }
            Task {
                await app.updateNotifyCoordinator.checkManually()
                let result = app.updateNotifyCoordinator.lastManualCheckResult
                if case .offered = result { return }
                if result != nil { sheets.showManualUpdateCheckResultAlert = true }
            }
        } label: {
            HStack {
                Text(SettingsRow.checkForUpdates.label)
                    .foregroundStyle(.primary)
                Spacer()
                if state.isCheckingForUpdate {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(state.isCheckingForUpdate)
    }

    private var serverStatusRow: some View {
        Button {
            openURL(AppURLs.serverStatus)
        } label: {
            HStack {
                Text(SettingsRow.serverStatus.label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var whatsNewRow: some View {
        Button {
            sheets.manualWhatsNewItem = app.flatMap { $0.updateNotifyCoordinator.latestWhatsNew(in: $0) }
        } label: {
            HStack {
                Text(SettingsRow.whatsNew.label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif
}

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var sheets = SettingsSheetState()

    var body: some View {
        SettingsList(sheets: sheets)
            .settingsEnvironment()
            .modifier(SettingsSheets(state: sheets))
    }
}

/// The Settings root, which reads the app only from its actions, so a test can show it.
struct SettingsList: View {
    let sheets: SettingsSheetState

    @Environment(\.settingsState) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var query: String
    @State private var isSearching = false
    @State private var revealed: SettingsRow?
    @State private var notificationsAuthorized = true
    @State private var storageBytes: Int?

    init(sheets: SettingsSheetState, query: String = "") {
        self.sheets = sheets
        _query = State(initialValue: query)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if query.allSatisfy(\.isWhitespace) {
                    sections
                } else {
                    SettingsSearchResults(query: query, state: state) { row in
                        (query, isSearching) = ("", false)
                        revealed = row
                    }
                }
            }
            .onChange(of: revealed) { _, row in
                guard let row else { return }
                revealed = nil
                Task { proxy.scrollTo(row, anchor: .center) }
            }
        }
        .searchable(text: $query, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .automatic))
        .navigationTitle(String(localized: "feature_settings"))
        .task { await refreshNotificationsAuthorization() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refreshNotificationsAuthorization() }
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        SettingsAccountSection(sheets: sheets)
        SettingsAppearanceSection(sheets: sheets)
        Section(String(localized: "settings_section_pages")) {
            ForEach(PageSettings.allCases.filter { $0.isShown(in: state) }) { page in
                NavigationLink(String(localized: page.titleKey)) { page.view }
            }
        }
        Section(String(localized: "cloud_sync_title")) {
            NavigationLink {
                CloudSyncSettingsView()
            } label: {
                LabeledContent(SettingsRow.tigerSync.label, value: String(localized: state.isCloudSyncOn
                    ? "settings_sync_status_on" : "settings_sync_status_off"))
            }
            .settingsRow(.tigerSync)
        }
        Section {
            if !notificationsAuthorized {
                Button(action: openSystemSettings) {
                    Label(
                        String(localized: "settings_notifications_disabled_warning"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            NavigationLink(SettingsRow.notificationPermissions.label) {
                NotificationPermissionSettingsView()
            }
            .settingsRow(.notificationPermissions)
        }
        // No in-app picker: the user picks the app language in the per-app
        // picker in iOS Settings, and iOS restarts the process on selection.
        Section(String(localized: "feature_category_language")) {
            Button(action: openSystemSettings) {
                HStack {
                    Text(SettingsRow.language.label)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsRow(.language)
        }
        otherSection
        SettingsAboutSection(sheets: sheets)
        #if DEBUG
        SettingsDeveloperSection()
        #endif
    }

    private var otherSection: some View {
        Section(String(localized: "settings_section_other_settings")) {
            NavigationLink(SettingsRow.apiEndpoint.label) {
                DebugEndpointView()
            }
            .settingsRow(.apiEndpoint)
            NavigationLink {
                StorageSettingsView()
            } label: {
                LabeledContent(SettingsRow.storage.label) {
                    Text(storageBytes.map(StorageSizes.text) ?? "…")
                        .monospacedDigit()
                }
            }
            .task { storageBytes = await StorageCleaner.live.measure().total }
            .settingsRow(.storage)
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func refreshNotificationsAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        notificationsAuthorized = status == .authorized || status == .provisional || status == .ephemeral
    }
}

/// Each result is named by its place and title. A page's row opens that page; a root row closes
/// the search and scrolls to the row.
private struct SettingsSearchResults: View {
    let query: String
    let state: SettingsState
    let reveal: (SettingsRow) -> Void

    var body: some View {
        let results = SettingsSearch.results(for: query, in: state)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        }
        ForEach(results) { result in
            switch result.row.place {
            case .page(let page):
                NavigationLink(result.text) { page.view }
            case .section:
                Button { reveal(result.row) } label: {
                    Text(result.text).foregroundStyle(.primary)
                }
            }
        }
    }
}

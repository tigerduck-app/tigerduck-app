import Observation
import SwiftUI

struct DebugEndpointView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = DebugEndpointViewModel()
    #if os(iOS)
    @FocusState private var fieldFocused: Bool
    #endif

    var body: some View {
        Form {
            Section {
                Text(viewModel.effectiveURL)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text(String(localized: "settings_api_endpoint_effective_title"))
            }

            if let stale = viewModel.staleOverride {
                Section {
                    Text(stale)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "settings_api_endpoint_stale_title"))
                } footer: {
                    Text(String(localized: "settings_api_endpoint_stale_description"))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                textField

                if let error = viewModel.validationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let note = viewModel.statusNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        #if os(iOS)
                        fieldFocused = false
                        #endif
                        Task { await viewModel.save { await EndpointChangeSignOut(appState: appState).notes() } }
                    } label: {
                        if viewModel.isChecking {
                            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                                ProgressView()
                                Text(String(localized: "settings_api_endpoint_checking"))
                            }
                        } else {
                            Text(String(localized: "action_save"))
                        }
                    }
                    .disabled(viewModel.isChecking || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button(String(localized: "settings_api_endpoint_reset_action"), role: .destructive) {
                        #if os(iOS)
                        fieldFocused = false
                        #endif
                        Task { await viewModel.resetToDefault { await EndpointChangeSignOut(appState: appState).notes() } }
                    }
                    .disabled(viewModel.isChecking || viewModel.storedOverride == nil)
                }
            } header: {
                Text(String(localized: "settings_api_endpoint_change_title"))
            } footer: {
                Text(String(localized: "settings_api_endpoint_https_note"))
            }
        }
        .navigationTitle(String(localized: "settings_api_endpoint"))
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .endpointChangeAlert(viewModel)
    }

    @ViewBuilder
    private var textField: some View {
        let placeholder = String(localized: "settings_api_endpoint_placeholder")
        #if os(iOS)
        TextField(placeholder, text: $viewModel.draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.system(.body, design: .monospaced))
            .focused($fieldFocused)
            .disabled(viewModel.isChecking)
        #else
        TextField(placeholder, text: $viewModel.draft)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .disabled(viewModel.isChecking)
        #endif
    }
}

@MainActor
@Observable
final class DebugEndpointViewModel {
    struct Backing {
        var currentOverride: () -> String? = { DebugEndpointStore.currentOverride() }
        var rejectedOverride: () -> String? = { DebugEndpointStore.storedButRejectedOverride() }
        var effectiveURL: () -> URL = { PushServerConfig.resolveServerURL() }
        var defaultURL: () -> URL = { PushServerConfig.defaultServerURL() }
        var check: (String) async -> DebugEndpointStore.CheckResult = { await DebugEndpointStore.check($0) }
        var store: (URL) async -> Bool = { await DebugEndpointStore.store($0) }
        var clear: () -> Void = { DebugEndpointStore.clearOverride() }
    }

    struct PendingChange: Equatable {
        let url: URL?
        var rewritten = false
        var notes: [String] = []
    }

    var draft: String
    private(set) var storedOverride: String?
    private(set) var staleOverride: String?
    private(set) var validationError: String?
    private(set) var statusNote: String?
    private(set) var effectiveURL: String
    private(set) var isChecking = false
    var pendingChange: PendingChange?
    private let backing: Backing

    init(backing: Backing = Backing()) {
        self.backing = backing
        let current = backing.currentOverride()
        let stale = backing.rejectedOverride()
        self.storedOverride = current
        self.staleOverride = stale
        self.draft = current ?? stale ?? ""
        self.effectiveURL = backing.effectiveURL().absoluteString
    }

    func save(notes: () async -> [String] = { [] }) async {
        guard !isChecking else { return }
        isChecking = true
        validationError = nil
        statusNote = nil
        defer { isChecking = false }

        let submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await backing.check(submitted) {
        case .accepted(let url):
            let change = PendingChange(
                url: url, rewritten: submitted.lowercased().hasPrefix("https://") && url.scheme == "http"
            )
            if AuthTokenManager.isSameBackend(url, backing.effectiveURL()) {
                await apply(change)
            } else {
                var asked = change
                asked.notes = await notes()
                pendingChange = asked
            }
        case .rejected(let reason):
            validationError = Self.message(for: reason)
        }
    }

    func resetToDefault(notes: () async -> [String] = { [] }) async {
        guard !isChecking else { return }
        isChecking = true
        validationError = nil
        statusNote = nil
        defer { isChecking = false }
        if AuthTokenManager.isSameBackend(backing.defaultURL(), backing.effectiveURL()) {
            await apply(PendingChange(url: nil))
        } else {
            pendingChange = PendingChange(url: nil, notes: await notes())
        }
    }

    func confirm(_ change: PendingChange, signingOut signOut: () async -> Void) async {
        pendingChange = nil
        guard !isChecking else { return }
        isChecking = true
        validationError = nil
        statusNote = nil
        defer { isChecking = false }

        await signOut()
        await apply(change)
    }

    private func apply(_ change: PendingChange) async {
        if let url = change.url {
            guard await backing.store(url) else {
                validationError = String(localized: "settings_api_endpoint_error_save_failed")
                return
            }
            statusNote = change.rewritten
                ? String(localized: "settings_api_endpoint_saved_rewritten")
                : String(localized: "settings_api_endpoint_saved")
        } else {
            backing.clear()
            statusNote = String(localized: "settings_api_endpoint_reset_done")
        }
        storedOverride = backing.currentOverride()
        staleOverride = backing.rejectedOverride()
        draft = storedOverride ?? ""
        effectiveURL = backing.effectiveURL().absoluteString
    }

    private static func message(for reason: DebugEndpointStore.Rejection) -> String {
        switch reason {
        case .malformed:
            String(localized: "settings_api_endpoint_error_malformed")
        case .insecure:
            String(localized: "settings_api_endpoint_error_insecure")
        case .unreachable(let detail):
            String(format: String(localized: "settings_api_endpoint_error_unreachable"), detail)
        case .notTigerDuck:
            String(localized: "settings_api_endpoint_error_not_backend")
        }
    }
}

@MainActor
struct EndpointChangeSignOut {
    let appState: AppState

    nonisolated static func endsSchoolAccount(hasCredentials: Bool, studentId: String?, backendSignedIn: Bool) -> Bool {
        hasCredentials || studentId != nil || backendSignedIn
    }

    func notes() async -> [String] {
        guard await endsSchoolAccount() else { return [] }
        var notes: [String] = []
        if await appState.signOutDeletesUnsyncedData() { notes.append(String(localized: "settings_sign_out_unsynced_data")) }
        if ImportedClassTableStore.shared.hasImportedClassTables {
            notes.append(String(localized: "settings_sign_out_imported_tables"))
        }
        return notes
    }

    func run() async {
        let calls: Task<Void, Never>? = await endsSchoolAccount()
            ? appState.logoutNTUST() : appState.authService.signOutCalls
        if appState.isLibraryLoggedIn { appState.logoutLibrary() }
        #if os(iOS)
        if MailAccountManager.shared.isLoggedIn { MailAccountManager.shared.logout() }
        #endif
        await calls?.value
    }

    private func endsSchoolAccount() async -> Bool {
        Self.endsSchoolAccount(
            hasCredentials: appState.authService.hasStoredCredentials,
            studentId: appState.authService.storedStudentId,
            backendSignedIn: await appState.authTokenManager.isLoggedIn
        )
    }
}

extension View {
    func endpointChangeAlert(_ viewModel: DebugEndpointViewModel) -> some View {
        modifier(EndpointChangeAlert(viewModel: viewModel))
    }
}

private struct EndpointChangeAlert: ViewModifier {
    let viewModel: DebugEndpointViewModel
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "settings_api_endpoint_change_alert_title"),
            isPresented: Binding(
                get: { viewModel.pendingChange != nil },
                set: { if !$0 { viewModel.pendingChange = nil } }
            ),
            presenting: viewModel.pendingChange
        ) { change in
            Button(String(localized: "settings_api_endpoint_change_alert_confirm"), role: .destructive) {
                Task { await viewModel.confirm(change) { await EndpointChangeSignOut(appState: appState).run() } }
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: { change in
            Text(([String(localized: "settings_api_endpoint_change_alert_message")] + change.notes)
                .joined(separator: "\n"))
        }
    }
}

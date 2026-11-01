import Foundation
import Observation

nonisolated struct MoodleNotificationAPI: Sendable {
    var load: @Sendable () async throws -> MoodleNotificationMatrix
    var save: @Sendable (_ preference: MoodleNotificationMatrix.Preference, _ signIn: SignIn) async throws -> Void

    static func live(
        chinese: Bool,
        tokens: MoodleWebserviceClient.TokenSource = .keychain,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) -> MoodleNotificationAPI {
        MoodleNotificationAPI(
            load: {
                try await MoodleWebserviceClient.withToken(tokens) {
                    try await MoodleNotificationPreferencesService.preferences(
                        chinese: chinese, token: $0, session: session, siteURL: siteURL
                    )
                }
            },
            save: { preference, signIn in
                try await MoodleWebserviceClient.withToken(tokens) {
                    try await MoodleNotificationPreferencesService.save(
                        preference, chinese: chinese, token: $0, for: signIn, session: session, siteURL: siteURL
                    )
                }
            }
        )
    }
}

/// The Moodle notification preferences page. Each write sends the whole processor list of its
/// preference, so one read or write runs at a time, and the page then shows what the server holds.
@Observable
@MainActor
final class MoodleNotificationSettings {
    private var shown = SignInBound<MoodleNotificationMatrix?>(empty: nil)
    private var chosenMethod: String?
    private(set) var loadFailure: (any Error)?
    private(set) var isBusy = false
    var saveFailure: String?

    @ObservationIgnored private let signIn: SignIn
    @ObservationIgnored private let api: MoodleNotificationAPI

    init(signIn: SignIn, api: MoodleNotificationAPI) {
        self.signIn = signIn
        self.api = api
    }

    var matrix: MoodleNotificationMatrix? { shown.value }

    var method: String {
        get {
            let ids = matrix?.methods.map(\.id) ?? []
            if let chosenMethod, ids.contains(chosenMethod) { return chosenMethod }
            return ids.first ?? ""
        }
        set { chosenMethod = newValue }
    }

    func isOn(_ preference: MoodleNotificationMatrix.Preference) -> Bool {
        preference.enabled.contains(method)
    }

    func canChange(_ preference: MoodleNotificationMatrix.Preference) -> Bool {
        guard let matrix else { return false }
        return !isBusy && !matrix.disablesAll && !preference.locked.contains(method)
    }

    /// A load while a write runs is skipped: the write reads the matrix again when it ends.
    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        loadFailure = nil
        do {
            shown.set(try await api.load(), for: signIn)
        } catch {
            loadFailure = error
        }
    }

    @discardableResult
    func set(_ on: Bool, for key: String) -> Task<Void, Never>? {
        guard let before = matrix, let preference = before.preference(key), canChange(preference) else { return nil }
        let changed = preference.setting(method, on: on)
        isBusy = true
        shown.set(before.replacing(changed), for: signIn)
        return Task { await save(changed, restoring: before) }
    }

    private func save(_ preference: MoodleNotificationMatrix.Preference, restoring before: MoodleNotificationMatrix) async {
        defer { isBusy = false }
        do {
            try await api.save(preference, signIn)
        } catch {
            shown.set(before, for: signIn)
            if !AppLogger.isCancellation(error) { saveFailure = MoodleFailure.message(for: error) }
            return
        }
        do {
            shown.set(try await api.load(), for: signIn)
        } catch {
            AppLogger.captureError(error, context: ["phase": "moodleNotifications.reload"])
        }
    }
}

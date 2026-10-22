import Foundation
import Defaults
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
@Observable
final class UpdateNotifyCoordinator {
    var pendingUpdate: PendingUpdate?

    var pendingWhatsNew: WhatsNewPresentation?

    var isCheckingForUpdate = false

    var lastManualCheckResult: ManualCheckResult?

    struct PendingUpdate: Equatable {
        let latestVersion: String
        let appStoreURL: URL
    }

    enum ManualCheckResult: Equatable {
        case upToDate
        case offered(PendingUpdate)
        case failed
    }

    typealias ErrorReporter = @Sendable (any Error, [String: String]) -> Void

    private let bundleId: String
    private let session: URLSession
    private let repository: WhatsNewRepository
    private let reportError: ErrorReporter
    private var inFlight: Task<LookupResult, Never>?

    private typealias Lookup = AppStoreUpdateService.Lookup

    private enum LookupResult: Equatable {
        case found(Lookup)
        case noRecord
        case failed
    }

    nonisolated init(
        bundleId: String = Bundle.main.bundleIdentifier ?? "org.ntust.app.TigerDuck",
        session: URLSession = .shared,
        repository: WhatsNewRepository? = nil,
        reportError: @escaping ErrorReporter = { AppLogger.captureError($0, context: $1) }
    ) {
        self.bundleId = bundleId
        self.session = session
        self.repository = repository ?? WhatsNewRepository()
        self.reportError = reportError
    }

    func hasWhatsNewContent(in appState: AppState) -> Bool {
        latestWhatsNew(in: appState) != nil
    }

    func latestWhatsNew(in appState: AppState) -> WhatsNewPresentation? {
        let languageTag = WhatsNewLanguage.currentLanguageTag
        let current = AppVersion.current
        return WhatsNewFlowBuilder.replay(
            language: WhatsNewLanguage(languageTag: languageTag),
            upTo: current,
            releases: WhatsNewCatalog.releases,
            latestSummary: repository.latestEntry(languageTag: languageTag, upTo: current),
            summaryFor: { repository.entry(forVersion: $0, languageTag: languageTag) },
            isApplicable: { $0.isApplicable(appState) }
        )
    }

    func evaluateWhatsNewOnLaunch(in appState: AppState) {
        let lastShown = Defaults[.lastShownWhatsNewVersion].flatMap(AppVersion.init)
        let current = AppVersion.current
        if let lastShown, !(lastShown < current) { return }

        let version = bundleVersionString
        let languageTag = WhatsNewLanguage.currentLanguageTag
        Defaults[.lastShownWhatsNewVersion] = version
        pendingWhatsNew = WhatsNewFlowBuilder.upgrade(
            from: lastShown,
            to: current,
            version: version,
            language: WhatsNewLanguage(languageTag: languageTag),
            releases: WhatsNewCatalog.releases,
            summary: repository.entry(forVersion: version, languageTag: languageTag),
            isApplicable: { $0.isApplicable(appState) }
        )
    }

    func acknowledgeWhatsNew() {
        Defaults[.lastShownWhatsNewVersion] = bundleVersionString
        pendingWhatsNew = nil
    }

    nonisolated func seedWhatsNewOnFreshInstall() {
        Defaults[.lastShownWhatsNewVersion] = Self.bundleVersionString
    }

    func checkInBackground() {
        #if os(iOS)
        guard Defaults[.hasCompletedOnboarding] else { return }
        #endif
        #if DEBUG
        if Self.consumeDebugSimulateUpdateFlag() {
            Task { await surfaceSyntheticUpdatePrompt() }
            return
        }
        #endif
        if let last = Defaults[.lastUpdateCheckAt] {
            let delta = Date().timeIntervalSince(last)
            if delta >= 0 && delta < AppConstants.updateCheckThrottle {
                return
            }
        }
        Task { await performCheck(manual: false) }
    }

    #if DEBUG
    private static let debugSimulateUpdateKey = "debug.simulateUpdateOnNextLaunch"

    static func armDebugSimulatedUpdate() {
        UserDefaults.standard.set(true, forKey: debugSimulateUpdateKey)
    }

    static var isDebugSimulatedUpdateArmed: Bool {
        UserDefaults.standard.bool(forKey: debugSimulateUpdateKey)
    }

    private static func consumeDebugSimulateUpdateFlag() -> Bool {
        let armed = UserDefaults.standard.bool(forKey: debugSimulateUpdateKey)
        if armed {
            UserDefaults.standard.removeObject(forKey: debugSimulateUpdateKey)
        }
        return armed
    }

    private func surfaceSyntheticUpdatePrompt() async {
        let appStoreURL: URL
        if case .found(let lookup)? = try? await AppStoreUpdateService.fetchLatest(
            bundleId: bundleId,
            session: session,
            country: AppConstants.appStoreLookupStorefront
        ) {
            appStoreURL = URL.knownGoodAppStoreLink(trackId: lookup.trackId)
        } else {
            appStoreURL = URL(string: "https://apps.apple.com/")!
        }
        pendingUpdate = PendingUpdate(latestVersion: "99.0.0", appStoreURL: appStoreURL)
    }
    #endif

    func checkManually() async {
        await performCheck(manual: true)
    }

    func handleUpdatePromptAction(_ action: UpdatePromptAction) {
        guard let pending = pendingUpdate else { return }
        switch action {
        case .updateNow:
            #if os(iOS)
            UIApplication.shared.open(pending.appStoreURL, options: [:], completionHandler: nil)
            #else
            NSWorkspace.shared.open(pending.appStoreURL)
            #endif
            pendingUpdate = nil
        case .later:
            Defaults[.lastPromptedUpdateVersion] = pending.latestVersion
            Defaults[.lastPromptedUpdateAt] = Date()
            pendingUpdate = nil
        case .skipThisVersion:
            Defaults[.skippedUpdateVersion] = pending.latestVersion
            pendingUpdate = nil
        }
    }

    enum UpdatePromptAction {
        case updateNow
        case later
        case skipThisVersion
    }

    #if os(iOS)

    var activeNotifySheet: NotifySheet? {
        if let entry = pendingWhatsNew { return .whatsNew(entry) }
        if let pending = pendingUpdate { return .update(pending) }
        return nil
    }

    func dismissActiveNotifySheet() {
        if pendingWhatsNew != nil {
            acknowledgeWhatsNew()
            return
        }
        if pendingUpdate != nil {
            pendingUpdate = nil
        }
    }
    #endif

    private func performCheck(manual: Bool) async {
        if manual {
            isCheckingForUpdate = true
            lastManualCheckResult = nil
        }
        defer { if manual { isCheckingForUpdate = false } }

        let result = await sharedLookup()
        switch result {
        case .found, .noRecord:
            Defaults[.lastUpdateCheckAt] = Date()
        case .failed:
            if manual { Defaults[.lastUpdateCheckAt] = Date() }
        }

        switch result {
        case .failed:
            if manual { lastManualCheckResult = .failed }
            return
        case .noRecord:
            if manual { lastManualCheckResult = .upToDate }
            return
        case .found:
            break
        }

        guard case let .found(lookup) = result else { return }

        guard let latest = AppVersion(lookup.version) else {
            reportUnparseableStoreVersion(lookup.version)
            if manual { lastManualCheckResult = .failed }
            return
        }

        guard latest > AppVersion.current else {
            if manual { lastManualCheckResult = .upToDate }
            return
        }

        if !manual, Defaults[.skippedUpdateVersion] == lookup.version {
            return
        }

        if !manual,
           Defaults[.lastPromptedUpdateVersion] == lookup.version,
           let lastPromptedAt = Defaults[.lastPromptedUpdateAt] {
            let delta = Date().timeIntervalSince(lastPromptedAt)
            if delta >= 0 && delta < AppConstants.updatePromptCooldown {
                return
            }
        }

        let appStoreURL = URL.knownGoodAppStoreLink(trackId: lookup.trackId)
        let pending = PendingUpdate(latestVersion: lookup.version, appStoreURL: appStoreURL)
        pendingUpdate = pending
        if manual { lastManualCheckResult = .offered(pending) }
    }

    private func reportUnparseableStoreVersion(_ version: String) {
        guard Defaults[.lastReportedUnparseableStoreVersion] != version else { return }
        Defaults[.lastReportedUnparseableStoreVersion] = version
        reportError(
            AppStoreUpdateService.LookupError.unparseableVersion,
            [
                "phase": "UpdateNotifyCoordinator.performCheck",
                "storeVersion": version,
            ]
        )
    }

    private func sharedLookup() async -> LookupResult {
        if let existing = inFlight {
            return await existing.value
        }
        let task = Task<LookupResult, Never> { [bundleId, session, reportError] in
            do {
                let outcome = try await AppStoreUpdateService.fetchLatest(
                    bundleId: bundleId,
                    session: session,
                    country: AppConstants.appStoreLookupStorefront
                )
                switch outcome {
                case .found(let lookup): return .found(lookup)
                case .noRecord: return .noRecord
                }
            } catch {
                reportError(error, ["phase": "AppStoreUpdateService.fetchLatest"])
                return .failed
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    nonisolated static var bundleVersionString: String {
        if let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return raw
        }
        assertionFailure("CFBundleShortVersionString missing from Bundle.main — What's New gate will use the 0.0.0 fallback.")
        return "0.0.0"
    }

    private var bundleVersionString: String { Self.bundleVersionString }
}

private extension URL {
    static func knownGoodAppStoreLink(trackId: Int) -> URL {
        var components = URLComponents()
        #if os(macOS)
        components.scheme = "macappstore"
        #else
        components.scheme = "https"
        #endif
        components.host = "apps.apple.com"
        components.path = "/app/id\(trackId)"
        return components.url ?? URL(string: "https://apps.apple.com/app/id\(trackId)")!
    }
}

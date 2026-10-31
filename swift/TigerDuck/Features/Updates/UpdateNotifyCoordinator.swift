import Foundation
import Defaults
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Owns the App Store "newer build?" check and the sheet flags it feeds. A child of ``AppEnvironment``
/// so views observe `pendingUpdate` and `pendingWhatsNew` through `@Environment(AppEnvironment.self)`.
///
/// On the Mac the lookup answers with the universal purchase's one record and no Mac version.
/// The Mac ships the same marketing version from the same target, so that version stands in,
/// and Update Now opens the Mac App Store page. What's New is iPhone-only; the Mac shows an
/// alert (`MacUpdateCheck.swift`). The 7-day same-version "Later" cooldown mirrors Android's
/// `UpdatePromptGate.COOLDOWN_MS`, and the What's New flow matches Android's, keyed by versionCode.
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

    typealias ErrorReporter = AppStoreLookup.ErrorReporter

    private let appStore: AppStoreLookup
    private let repository: WhatsNewRepository

    nonisolated init(
        bundleId: String = Bundle.main.bundleIdentifier ?? "org.ntust.app.TigerDuck",
        session: URLSession = .shared,
        repository: WhatsNewRepository? = nil,
        reportError: @escaping ErrorReporter = { AppLogger.captureError($0, context: $1) }
    ) {
        appStore = AppStoreLookup(bundleId: bundleId, session: session, reportError: reportError)
        self.repository = repository ?? WhatsNewRepository()
    }

    func hasWhatsNewContent(in app: AppEnvironment) -> Bool {
        latestWhatsNew(in: app) != nil
    }

    func latestWhatsNew(in app: AppEnvironment) -> WhatsNewPresentation? {
        let languageTag = WhatsNewLanguage.currentLanguageTag
        let current = AppVersion.current
        return WhatsNewFlowBuilder.replay(
            language: WhatsNewLanguage(languageTag: languageTag),
            upTo: current,
            releases: WhatsNewCatalog.releases,
            latestSummary: repository.latestEntry(languageTag: languageTag, upTo: current),
            summaryFor: { repository.entry(forVersion: $0, languageTag: languageTag) },
            isApplicable: { $0.isApplicable(app) }
        )
    }

    func evaluateWhatsNewOnLaunch(in app: AppEnvironment) {
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
            isApplicable: { $0.isApplicable(app) }
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
        if DebugSimulatedUpdate.consume() {
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
    private func surfaceSyntheticUpdatePrompt() async {
        let appStoreURL = await appStore.anyStoreLink() ?? URL(string: "https://apps.apple.com/")!
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

    /// Single sheet item consumed by ``updateNotifySheetHost()``. Both
    /// pending flags fold into the same `.sheet(item:)` to avoid the
    /// SwiftUI race that stacking two `.sheet(item:)` modifiers on the
    /// same view introduces. What's New presents first when both are
    /// set so the upgrade summary is read before the next-version
    /// prompt — dismissing it lets the update prompt take its place on
    /// the next observation cycle.
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

        let result = await appStore.latest()
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
            // Apple has no public record (TestFlight, or an unlisted region), so nothing newer is
            // public: a manual check reports up to date and a background check does nothing.
            if manual { lastManualCheckResult = .upToDate }
            return
        case .found:
            break
        }

        guard case let .found(lookup) = result else { return }

        guard let latest = AppVersion(lookup.version) else {
            appStore.reportUnparseableVersion(lookup.version)
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

        let pending = PendingUpdate(latestVersion: lookup.version, appStoreURL: AppStoreLookup.storeLink(trackId: lookup.trackId))
        pendingUpdate = pending
        if manual { lastManualCheckResult = .offered(pending) }
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

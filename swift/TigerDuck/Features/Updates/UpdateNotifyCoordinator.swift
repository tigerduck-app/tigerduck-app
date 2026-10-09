import Foundation
import Defaults
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Owns the App Store "newer build?" check and the sheet flags it feeds. A child of ``AppState``
/// so views observe `pendingUpdate` and `pendingWhatsNew` through `@Environment(AppState.self)`.
///
/// On the Mac the lookup answers with the universal purchase's one record and no Mac version.
/// The Mac ships the same marketing version from the same target, so that version stands in,
/// and Update Now opens the Mac App Store page. What's New is iPhone-only; the Mac shows an
/// alert (`MacUpdateCheck.swift`). The 7-day same-version "Later" cooldown mirrors Android's
/// `UpdatePromptGate.COOLDOWN_MS`, and the What's New flow matches Android's, keyed by versionCode.
@MainActor
@Observable
final class UpdateNotifyCoordinator {
    /// Latest discovered App-Store-vs-installed mismatch. Set when a
    /// check finds `latest > current` AND that version is not in
    /// `Defaults[.skippedUpdateVersion]` AND the same-version cooldown
    /// has elapsed. Views observe this to drive the update sheet;
    /// `handleUpdatePromptAction` clears it on accept / later / skip.
    var pendingUpdate: PendingUpdate?

    /// What's New flow to present on the next eligible launch. Set by
    /// ``evaluateWhatsNewOnLaunch(in:)`` when the installed version moved
    /// past `lastShownWhatsNewVersion` and the skipped releases left
    /// anything to show — feature pages from ``WhatsNewCatalog`` or a
    /// summary for the running version in `whatsnew.json`.
    var pendingWhatsNew: WhatsNewPresentation?

    /// True while a manual "Check for Updates" tap is in flight. Surface
    /// in Settings so the row can show a spinner instead of a button.
    var isCheckingForUpdate = false

    /// Result of the most recent *manual* check (Settings tap). Lets the
    /// Settings row surface "you're up to date" / "couldn't reach the
    /// App Store" feedback without driving the full update sheet.
    /// Cleared each time a new manual check starts.
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

    /// Where the check's errors go: Sentry in the app, a recorder in tests.
    typealias ErrorReporter = @Sendable (any Error, [String: String]) -> Void

    private let bundleId: String
    private let session: URLSession
    private let repository: WhatsNewRepository
    private let reportError: ErrorReporter
    /// Coalesces concurrent calls — a manual "Check now" tap that lands
    /// while the scene-active background check is mid-flight reuses the
    /// in-flight task rather than firing a duplicate iTunes Lookup hit.
    private var inFlight: Task<LookupResult, Never>?

    private typealias Lookup = AppStoreUpdateService.Lookup

    /// Internal tri-state mirroring the service's distinction between
    /// "Apple replied with no record" (legit pre-launch — DO stamp the
    /// throttle, do NOT surface a failure alert) and "couldn't reach
    /// Apple" (retry next foreground, surface failure on manual taps).
    /// Collapsing both into a single `nil` was the original bug.
    private enum LookupResult: Equatable {
        case found(Lookup)
        case noRecord
        case failed
    }

    /// Nonisolated so `AppState` (a non-`@MainActor` `@Observable`) can
    /// construct this in its stored-property initializer without a
    /// concurrency hop. The init only assigns `let` properties — no
    /// MainActor-isolated state is touched.
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

    // MARK: - What's New

    /// True iff there is anything to replay — catalog pages that apply
    /// or a summary in `whatsnew.json` for the current locale resolution.
    /// Drives the Settings → What's New row's visibility.
    func hasWhatsNewContent(in appState: AppState) -> Bool {
        latestWhatsNew(in: appState) != nil
    }

    /// Newest release's flow, up to the installed version, for the current
    /// locale — independent of `lastShownWhatsNewVersion`. Backs the
    /// Settings → What's New entry point, which is allowed to re-present
    /// the same content; pages that don't apply to `appState` stay out.
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

    /// Call at launch, after onboarding, to decide whether to show What's New. A marker at or past
    /// the running version means it was handled. Otherwise the marker moves to the running version
    /// at once, shown or not, so it means "last version opened" as on Android: a page that
    /// `isApplicable` skipped cannot resurface on a later upgrade, and repeat calls are idempotent;
    /// `MainTabView.onAppear` re-fires on language changes (the `.id(rootLanguageId)` rebuild).
    /// The flow stacks feature pages from every release since the marker, then this version's
    /// summary. A missing marker (an upgrade from a build before it; fresh installs are seeded)
    /// counts this version only. A bug-fix release with nothing to show stays silent.
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

    /// Sticky write that advances `lastShownWhatsNewVersion` to the
    /// running bundle version — called by the sheet's Continue button
    /// and by the swipe-to-dismiss path in `UpdateNotifySheetHost`.
    /// Persisting the installed marketing string (not the entry's
    /// `version`) means a fresh install at v1.7.0 with no registered
    /// entry still seeds the key, so the next release with an entry
    /// triggers the prompt.
    func acknowledgeWhatsNew() {
        Defaults[.lastShownWhatsNewVersion] = bundleVersionString
        pendingWhatsNew = nil
    }

    /// Fresh-install seed: stamps the running bundle version so the launch-time gate treats it as
    /// seen. Called once from AppState's first-install branch; without it, a brand-new install has
    /// no `lastShownWhatsNewVersion` and would show a What's New sheet for the version just
    /// downloaded.
    ///
    /// `nonisolated` so `AppState.init`, also nonisolated, can call it without a MainActor hop.
    /// It only writes through `Defaults`, which is thread-safe.
    nonisolated func seedWhatsNewOnFreshInstall() {
        Defaults[.lastShownWhatsNewVersion] = Self.bundleVersionString
    }

    // MARK: - Update check

    /// Background check: respects the 24 h throttle and sets only `pendingUpdate`, never
    /// `lastManualCheckResult`. Safe on every scene-active transition; the throttle eats repeats.
    ///
    /// A no-op while onboarding is on screen: the sheet host mounts only on `MainTabView`, so a
    /// prompt set then would be stranded and pop over the first home screen when onboarding ends.
    /// `MainTabView.onAppear` runs the first real check after onboarding. The Mac has no onboarding
    /// sheet to strand a prompt behind, so it checks from the first launch, signed in or not.
    func checkInBackground() {
        #if os(iOS)
        guard Defaults[.hasCompletedOnboarding] else { return }
        #endif
        #if DEBUG
        // The debug Triggers page can request a synthetic update prompt for the next launch. It is
        // consumed once and surfaced before the throttle and the iTunes Lookup, so it works even
        // right after a real check.
        if Self.consumeDebugSimulateUpdateFlag() {
            Task { await surfaceSyntheticUpdatePrompt() }
            return
        }
        #endif
        if let last = Defaults[.lastUpdateCheckAt] {
            let delta = Date().timeIntervalSince(last)
            // `delta >= 0` ignores a future timestamp (clock skew, a backup restore, a manual date
            // change): a negative delta is trivially `< throttle` and would suppress checks until
            // real time caught up with the bogus stamp.
            if delta >= 0 && delta < AppConstants.updateCheckThrottle {
                return
            }
        }
        Task { await performCheck(manual: false) }
    }

    #if DEBUG
    /// Debug-only UserDefaults flag set by the Triggers page so the next
    /// background check surfaces a fake update prompt. The key is plain
    /// UserDefaults (not `Defaults` typed-keys) on purpose — it never
    /// ships in Release, and constraining it to debug code keeps the
    /// production storage surface clean.
    private static let debugSimulateUpdateKey = "debug.simulateUpdateOnNextLaunch"

    /// Arm a fake update prompt for the next scene-active / app launch.
    /// Called from the Triggers debug page; consumed by
    /// ``checkInBackground()``.
    static func armDebugSimulatedUpdate() {
        UserDefaults.standard.set(true, forKey: debugSimulateUpdateKey)
    }

    /// True iff the debug arm flag is currently set. Lets the Triggers
    /// page surface "armed — relaunch to fire" feedback.
    static var isDebugSimulatedUpdateArmed: Bool {
        UserDefaults.standard.bool(forKey: debugSimulateUpdateKey)
    }

    /// Atomic read-and-clear so a single arm fires exactly one synthetic
    /// prompt, not one per scene-active for the rest of the session.
    private static func consumeDebugSimulateUpdateFlag() -> Bool {
        let armed = UserDefaults.standard.bool(forKey: debugSimulateUpdateKey)
        if armed {
            UserDefaults.standard.removeObject(forKey: debugSimulateUpdateKey)
        }
        return armed
    }

    /// Plant a synthetic ``PendingUpdate`` so the regular sheet host
    /// surfaces the prompt. Now that the app is published, resolve the
    /// real App Store deep link through the same iTunes Lookup the
    /// production path uses, so the debug prompt's "Update Now" opens the
    /// actual product page instead of the App Store homepage. Falls back
    /// to the homepage only if the lookup can't be reached (offline, or
    /// no public record yet).
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
        // "99.0.0", the debug prompt's sentinel, is above any shipping version: the real lookup
        // would also call it newer, so the prompt is built like a real one. It also reads as
        // plainly not a release, so it cannot pass for a real update on screen.
        pendingUpdate = PendingUpdate(latestVersion: "99.0.0", appStoreURL: appStoreURL)
    }
    #endif

    /// User-initiated "Check for Updates" in Settings. Always hits the
    /// network, populates `lastManualCheckResult` so the Settings row
    /// can react, and (if an update is found) also sets `pendingUpdate`
    /// so the same sheet path triggers.
    func checkManually() async {
        await performCheck(manual: true)
    }

    /// Three-button dispatch for the update prompt's actions.
    func handleUpdatePromptAction(_ action: UpdatePromptAction) {
        guard let pending = pendingUpdate else { return }
        switch action {
        case .updateNow:
            #if os(iOS)
            UIApplication.shared.open(pending.appStoreURL, options: [:], completionHandler: nil)
            #else
            NSWorkspace.shared.open(pending.appStoreURL)
            #endif
            // Clear now: the next foreground re-runs `checkInBackground()`, which re-arms only if
            // `latest > installed` still holds. Once the update installs they are equal, so no
            // separate "I updated" signal is needed.
            pendingUpdate = nil
        case .later:
            // Stamp the prompted version and time so that version is suppressed for
            // ``AppConstants/updatePromptCooldown``. Only the same version is: a newer one on the
            // store re-arms the prompt at once.
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
    // MARK: - Sheet binding

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

    /// Called by the sheet host when SwiftUI clears its binding (swipe to dismiss, tap outside on
    /// iPad, etc.):
    ///   * What's New: advance `lastShownWhatsNewVersion`, as a Continue tap does, so the gate
    ///     does not re-arm on the next launch.
    ///   * Update prompt: clear the pending flag without stamping the "Later" cooldown, so the
    ///     next throttle-elapsed background check may re-arm. Tapping Later goes through
    ///     ``handleUpdatePromptAction(_:)``, which does stamp it.
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

    // MARK: - Private

    private func performCheck(manual: Bool) async {
        if manual {
            isCheckingForUpdate = true
            lastManualCheckResult = nil
        }
        defer { if manual { isCheckingForUpdate = false } }

        let result = await sharedLookup()
        // Any answer from Apple stamps the throttle, even "no record" during TestFlight, so not
        // every scene-active runs an iTunes Lookup. A `.failed` lookup does not, so a brief offline
        // launch retries next foreground. A manual check always stamps, so background ones wait.
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

        // An unreadable store version says nothing about whether this build is current; calling it
        // up to date would hide a real update, so it is reported and a manual check fails instead.
        guard let latest = AppVersion(lookup.version) else {
            reportUnparseableStoreVersion(lookup.version)
            if manual { lastManualCheckResult = .failed }
            return
        }

        guard latest > AppVersion.current else {
            if manual { lastManualCheckResult = .upToDate }
            return
        }

        // "Skip This Version" suppression, which manual checks ignore: a user who taps Check for
        // Updates in Settings is asking again, and a version they skipped is still available.
        if !manual, Defaults[.skippedUpdateVersion] == lookup.version {
            return
        }

        // The 7-day "Later" cooldown covers only the version the sheet showed; manual checks bypass
        // it as with Skip, and a newer version re-arms. `delta >= 0` releases it for a future stamp
        // (clock skew): a negative delta is trivially `< cooldown` and would last indefinitely.
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

    /// Reports an unreadable store version once per version per install.
    /// The 24h throttle cannot do this on its own: manual checks skip it,
    /// so every "Check for Updates" tap would send the same report again.
    /// A later store version that is also unreadable is reported afresh.
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
                // Pin the storefront so users abroad / on a VPN don't
                // get an IP-inferred storefront that returns no record
                // and silently masks an available update.
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

    /// Static + nonisolated so the fresh-install seed (also nonisolated)
    /// can read it without a MainActor hop. Falls back to `"0.0.0"` so the
    /// gate fails closed; a DEBUG assertion surfaces the underlying
    /// bundle misconfiguration rather than letting it silently inert the
    /// feature.
    nonisolated static var bundleVersionString: String {
        if let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return raw
        }
        assertionFailure("CFBundleShortVersionString missing from Bundle.main — What's New gate will use the 0.0.0 fallback.")
        return "0.0.0"
    }

    /// Instance accessor for call sites already on the MainActor (the
    /// rest of the coordinator). Same value, no concurrency hop.
    private var bundleVersionString: String { Self.bundleVersionString }
}

private extension URL {
    /// `https://apps.apple.com/app/id<trackId>` — the canonical App
    /// Store deep link. Tapping it on a device with the App Store
    /// installed opens the product page directly; falls back to a web
    /// view on Mac Catalyst / device-less Simulator runs.
    static func knownGoodAppStoreLink(trackId: Int) -> URL {
        // Build through URLComponents so a future trackId edit can't
        // produce a malformed literal that crashes the open call.
        var components = URLComponents()
        #if os(macOS)
        // Straight into the Mac App Store, rather than Safari first.
        components.scheme = "macappstore"
        #else
        components.scheme = "https"
        #endif
        components.host = "apps.apple.com"
        components.path = "/app/id\(trackId)"
        // URLComponents always returns non-nil here for a well-formed
        // scheme+host+path, but guarding keeps the call site honest if
        // the path template ever changes.
        return components.url ?? URL(string: "https://apps.apple.com/app/id\(trackId)")!
    }
}

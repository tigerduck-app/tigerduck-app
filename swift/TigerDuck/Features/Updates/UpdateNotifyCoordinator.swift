#if os(iOS)
import Foundation
import Defaults
import UIKit

/// Owns the "newer build on App Store?" check and the sheet-presentation
/// flags it feeds. Lives as a child of ``AppState`` so SwiftUI views can
/// observe `pendingUpdate` / `pendingWhatsNew` through the same
/// `@Environment(AppState.self)` they already use for everything else.
///
/// **Why iOS-only**: the Mac App Store surfaces its own Updates tab,
/// and the iTunes Lookup endpoint indexes iOS App Store records only —
/// running this on Mac would either silently no-op or deep-link into
/// the iPhone App Store from inside a Mac binary, both of which are
/// worse than no prompt.
///
/// **Cross-platform alignment**: the gating constants mirror Android's
/// `UpdatePromptGate.COOLDOWN_MS` (7 days, same available version after
/// "Later") and the What's New content schema mirrors Android's
/// `assets/whatsnew.json` so the same release notes render on both
/// platforms.
@MainActor
@Observable
final class UpdateNotifyCoordinator {
    /// Latest discovered App-Store-vs-installed mismatch. Set when a
    /// check finds `latest > current` AND that version is not in
    /// `Defaults[.skippedUpdateVersion]` AND the same-version cooldown
    /// has elapsed. Views observe this to drive the update sheet;
    /// `handleUpdatePromptAction` clears it on accept / later / skip.
    var pendingUpdate: PendingUpdate?

    /// What's New entry to present on the next eligible launch. Set by
    /// ``evaluateWhatsNewOnLaunch()`` when the installed version moved
    /// past `lastShownWhatsNewVersion` and an entry is registered for
    /// the running version in `whatsnew.json`.
    var pendingWhatsNew: WhatsNewRepository.ResolvedWhatsNew?

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

    private let bundleId: String
    private let session: URLSession
    private let repository: WhatsNewRepository
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
        repository: WhatsNewRepository? = nil
    ) {
        self.bundleId = bundleId
        self.session = session
        self.repository = repository ?? WhatsNewRepository()
    }

    // MARK: - What's New

    /// Resolved language tag passed to the What's New repository. Reads
    /// the in-app override first (`AppLanguage`-keyed setting), then
    /// falls back to the device locale. Wrapping this lets the manual
    /// "Open What's New" Settings entry and the launch-time auto-open
    /// stay in lockstep.
    private var resolvedLanguageTag: String {
        let stored = Defaults[.appLanguage]
        if stored.lowercased() != "system" { return stored }
        return Locale.current.identifier
    }

    /// True iff at least one entry is registered in `whatsnew.json` for
    /// the current locale resolution. Drives the Settings → What's New
    /// row's visibility.
    var hasWhatsNewContent: Bool {
        repository.hasAnyContent(languageTag: resolvedLanguageTag)
    }

    /// Latest authored entry for the current locale, independent of
    /// `lastShownWhatsNewVersion`. Backs the Settings → What's New
    /// entry point, which is allowed to re-present the same content.
    var latestWhatsNew: WhatsNewRepository.ResolvedWhatsNew? {
        repository.latestEntry(languageTag: resolvedLanguageTag)
    }

    /// Call once during app launch, after onboarding has completed, to
    /// decide whether to surface the What's New sheet. The decision rule
    /// mirrors Android's `WhatsNewGate.shouldShow`:
    ///
    /// 1. `lastShownWhatsNewVersion` is set (a brand-new install seeded
    ///    it during fresh-install handling, so this branch fails for
    ///    first-launch users — they haven't missed anything).
    /// 2. The running version is strictly greater than the last seen
    ///    version.
    /// 3. `whatsnew.json` has a usable entry for the running version
    ///    in the resolved locale.
    func evaluateWhatsNewOnLaunch() {
        guard let lastShownRaw = Defaults[.lastShownWhatsNewVersion],
              let lastShown = AppVersion(lastShownRaw)
        else {
            // Fresh installs that completed the seed land here with a
            // valid `lastShownRaw`; only path that legitimately lacks
            // one is "upgrade from a version that predated this
            // feature". Surface What's New in that case too.
            return surfaceLatestIfAvailable()
        }
        guard lastShown < AppVersion.current else { return }
        let current = bundleVersionString
        if let entry = repository.entry(forVersion: current, languageTag: resolvedLanguageTag) {
            present(entry)
        }
        // No registered entry for the running version → silent skip
        // (matches Android: a bug-fix release with no JSON entry should
        // NOT pop a dialog).
    }

    /// Fallback path for users upgrading from a pre-feature version
    /// (no `lastShownWhatsNewVersion` set). Only surface the latest
    /// entry when its version actually matches the running bundle —
    /// otherwise a release that forgot to add a `whatsnew.json` entry
    /// would pop the *previous* version's sheet ("What's new in 1.7.0"
    /// to a 1.8.0 user), which is worse than no prompt.
    private func surfaceLatestIfAvailable() {
        guard let entry = latestWhatsNew,
              entry.version == bundleVersionString
        else { return }
        present(entry)
    }

    /// Set `pendingWhatsNew` AND advance the seen marker in the same
    /// pass. Stamping eagerly (rather than only on dismiss) makes
    /// `evaluateWhatsNewOnLaunch()` idempotent across the repeated
    /// `MainTabView.onAppear` firings caused by `ContentView`'s
    /// `.id(rootLanguageId)` rebuild on every language change — without
    /// this, a remount before the user has tapped Continue would
    /// re-present the sheet on every language toggle in the same
    /// session. The `acknowledgeWhatsNew()` call from the sheet's
    /// dismiss path is then an idempotent re-write of the same key.
    private func present(_ entry: WhatsNewRepository.ResolvedWhatsNew) {
        pendingWhatsNew = entry
        Defaults[.lastShownWhatsNewVersion] = bundleVersionString
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

    /// Fresh-install seed: stamp the running bundle version so the
    /// launch-time gate treats it as already seen and skips the auto
    /// prompt. Called once from AppState's first-install branch —
    /// without this seed, `lastShownWhatsNewVersion == nil` after a
    /// brand-new install would fall through to "surface latest" and
    /// present a "What's New in vN" sheet for a freshly downloaded
    /// version.
    ///
    /// `nonisolated` so it can be called from `AppState.init` (also
    /// nonisolated) without a MainActor hop. Only writes through
    /// `Defaults`, which is thread-safe.
    nonisolated func seedWhatsNewOnFreshInstall() {
        Defaults[.lastShownWhatsNewVersion] = Self.bundleVersionString
    }

    // MARK: - Update check

    /// Background check — respects the 24h throttle and only sets
    /// `pendingUpdate` (never `lastManualCheckResult`). Safe to call on
    /// every scene-active transition; the throttle eats the dupes.
    ///
    /// Refuses to fire while onboarding is still on screen, otherwise a
    /// pending prompt set during onboarding would be stranded (the
    /// sheet host only mounts on `MainTabView`) and then pop on top of
    /// the user's first home screen the instant they complete the
    /// onboarding hand-off. Calls during onboarding no-op silently; the
    /// `MainTabView.onAppear` post-onboarding kicks off the first real
    /// check.
    func checkInBackground() {
        guard Defaults[.hasCompletedOnboarding] else { return }
        #if DEBUG
        // Debug "Triggers" page can request a synthetic update prompt
        // on next launch — consumed once and surfaced before any real
        // throttle / iTunes Lookup so it works even when a recent real
        // check has been throttled.
        if Self.consumeDebugSimulateUpdateFlag() {
            surfaceSyntheticUpdatePrompt()
            return
        }
        #endif
        if let last = Defaults[.lastUpdateCheckAt] {
            let delta = Date().timeIntervalSince(last)
            // `delta >= 0` filters a future-stamped timestamp (clock
            // skew, restore-from-backup, manual Settings → Date & Time
            // adjustment): a negative delta is `< throttle` trivially
            // true, which would otherwise suppress checks until real
            // time caught up to the bogus future stamp.
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
    /// surfaces the prompt. The URL points at the App Store homepage so
    /// "Update Now" doesn't 404 on a real device — we don't have a real
    /// `trackId` to deep-link to during pre-launch debug.
    private func surfaceSyntheticUpdatePrompt() {
        guard let url = URL(string: "https://apps.apple.com/") else { return }
        // "99.0.0" is the sentinel version surfaced in the debug update
        // prompt. Picked to be unambiguously larger than any shipping
        // TigerDuck version for the foreseeable future, so:
        //   1. The real iTunes Lookup pipeline (if it were running)
        //      would also classify it as "newer than installed" — keeps
        //      the simulated prompt structurally identical to a real
        //      one rather than going through a special debug code path.
        //   2. The version string reads as "obviously not a real
        //      release" on screen, so the debug-triggered prompt is
        //      visually distinguishable from a real available update.
        pendingUpdate = PendingUpdate(latestVersion: "99.0.0", appStoreURL: url)
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
            UIApplication.shared.open(pending.appStoreURL, options: [:], completionHandler: nil)
            // Clear the prompt immediately. The next foreground re-runs
            // `checkInBackground()` and only re-arms if `latest >
            // installed` still holds — once the App Store install
            // completes, installed == latest and the prompt stays
            // quiet without needing a separate "I updated" signal.
            pendingUpdate = nil
        case .later:
            // Stamp the prompted version + timestamp so the same
            // version is suppressed for ``AppConstants/updatePromptCooldown``.
            // A NEWER version landing on the store re-arms the prompt
            // immediately — only the same-version case is suppressed.
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

    /// Called by the sheet host when SwiftUI clears its binding (swipe
    /// to dismiss, tap outside on iPad, etc). Mirrors the per-sheet
    /// dismissal semantics each surface had when they lived in
    /// independent `.sheet(item:)` modifiers:
    ///   * What's New: advance `lastShownWhatsNewVersion` so the gate
    ///     does not re-arm on the next launch (same as a Continue tap).
    ///   * Update prompt: clear the pending flag without stamping the
    ///     "Later" cooldown — the next throttle-elapsed background check
    ///     is free to re-arm. Tapping a button on the prompt instead
    ///     routes through ``handleUpdatePromptAction(_:)`` and DOES
    ///     stamp.
    func dismissActiveNotifySheet() {
        if pendingWhatsNew != nil {
            acknowledgeWhatsNew()
            return
        }
        if pendingUpdate != nil {
            pendingUpdate = nil
        }
    }

    // MARK: - Private

    private func performCheck(manual: Bool) async {
        if manual {
            isCheckingForUpdate = true
            lastManualCheckResult = nil
        }
        defer { if manual { isCheckingForUpdate = false } }

        let result = await sharedLookup()
        // Stamp the throttle on ANY successful answer from Apple
        // (including "no record yet" during the TestFlight phase) so
        // the dormant lifecycle state does not generate one iTunes
        // Lookup per scene-active. Real network failures (`.failed`)
        // skip the stamp so a brief offline state at launch retries
        // on the next foreground. Manual taps always stamp so the
        // next background trigger respects the throttle.
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
            // Apple has no public record — TestFlight phase or
            // unlisted region. Treat as "you're on the latest"
            // for manual UX (the user is on whatever build they
            // installed; nothing newer is publicly available) and
            // quietly no-op for background checks.
            if manual { lastManualCheckResult = .upToDate }
            return
        case .found:
            break
        }

        guard case let .found(lookup) = result else { return }

        guard
            let latest = AppVersion(lookup.version),
            latest > AppVersion.current
        else {
            if manual { lastManualCheckResult = .upToDate }
            return
        }

        // "Skip This Version" suppression. Manual checks deliberately
        // ignore it — a user opening Settings → Check for Updates is
        // explicitly re-asking, and we shouldn't pretend nothing is
        // available because they previously waved off the same version.
        if !manual, Defaults[.skippedUpdateVersion] == lookup.version {
            return
        }

        // 7-day same-version cooldown for "Later". Manual checks bypass
        // (same reasoning as Skip). A NEWER version always re-arms —
        // the cooldown only suppresses the exact `lookup.version`
        // already presented via the sheet. The `delta >= 0` guard
        // releases the cooldown for a future-stamped timestamp (clock
        // skew); a negative delta is trivially `< cooldown` and would
        // otherwise suppress the prompt indefinitely.
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

    private func sharedLookup() async -> LookupResult {
        if let existing = inFlight {
            return await existing.value
        }
        let task = Task<LookupResult, Never> { [bundleId, session] in
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
                AppLogger.captureError(
                    error,
                    context: ["phase": "AppStoreUpdateService.fetchLatest"]
                )
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
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/app/id\(trackId)"
        // URLComponents always returns non-nil here for a well-formed
        // scheme+host+path, but guarding keeps the call site honest if
        // the path template ever changes.
        return components.url ?? URL(string: "https://apps.apple.com/app/id\(trackId)")!
    }
}
#endif

import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// Keychain-backed API endpoint override, set in Settings → Other settings → API endpoint, on
/// onboarding's sign-in page or in the Mac settings, and honoured by every build. The Keychain
/// keeps it through the reinstalls done to retest fresh installs against another backend, never
/// restores it via iCloud and lets a launch behind the lock screen read it. A value is stored only
/// if ``PushServerConfig/isOverrideAllowed(_:)`` and ``EndpointHealthCheck/probe(_:)`` accept it
/// and the user agrees to the sign-out that comes with a change. Set and clear call
/// ``AcademicCalendarStore/endpointDidChange()``: the calendar's ETag does not name its backend,
/// so the next server could answer 304 against the old server's dates.
nonisolated enum DebugEndpointStore {
    /// Internal (not private) so the erase-everything action can name the
    /// one key it deliberately preserves.
    static let keychainKey = "debug_api_endpoint_override"

    /// Every backend request resolves its URL through ``currentOverride()``, the revision poll
    /// included, so the Keychain is read once and again only after a change or an unlock.
    #if os(iOS)
    private static let stored = KeychainReadCache(
        load: { try KeychainManager.loadStringIfReadable(key: keychainKey) },
        forgetOn: [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ]
    )
    #else
    private static let stored = KeychainReadCache(load: { try KeychainManager.loadStringIfReadable(key: keychainKey) })
    #endif

    /// Why ``check(_:)`` turned a candidate endpoint down.
    enum Rejection: Equatable {
        /// Not parseable as a URL with a scheme and a host.
        case malformed
        /// Parsed, but points at a routable address over plain HTTP.
        case insecure
        /// Passed validation, but the health probe found nothing serving.
        case unreachable(detail: String)
        /// Something answered the health probe, but not this backend.
        case notTigerDuck
    }

    /// Returns the stored override URL string, or nil if none is set or
    /// the stored value no longer passes the safety gate (e.g. the
    /// transport rules tightened after the value was saved).
    static func currentOverride() -> String? {
        guard let raw = stored.value(),
              !raw.isEmpty,
              let url = URL(string: raw),
              PushServerConfig.isOverrideAllowed(url)
        else { return nil }
        return raw
    }

    /// Returns the stored override when it fails ``PushServerConfig/isOverrideAllowed(_:)``, for
    /// example after a later build tightened the transport rules, so the UI can explain why a
    /// saved override stopped taking effect instead of falling back to the default without a word.
    ///
    /// This checks validation, not liveness: an endpoint that is merely down still reads as the
    /// active override, because the app is still trying to talk to it.
    static func storedButRejectedOverride() -> String? {
        guard let raw = stored.value(),
              !raw.isEmpty
        else { return nil }
        if let url = URL(string: raw), PushServerConfig.isOverrideAllowed(url) {
            return nil
        }
        return raw
    }

    /// What ``check(_:)`` makes of a candidate endpoint.
    enum CheckResult: Equatable {
        /// A TigerDuck backend answered at this normalized URL. Nothing is stored yet.
        case accepted(URL)
        case rejected(Rejection)
    }

    /// Validates `value` and probes it, storing nothing, so the user is asked before the endpoint
    /// changes (``store(_:)``).
    ///
    /// The probe runs before any write on purpose: this endpoint is where every later request
    /// goes, including the ones that fetch the screens the user would need to fix a bad value.
    /// The result tells a typo from a host that is simply down.
    static func check(_ value: String) async -> CheckResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed), parsed.host != nil else {
            return .rejected(.malformed)
        }
        let url = PushServerConfig.normalize(parsed)
        guard PushServerConfig.isOverrideAllowed(url) else { return .rejected(.insecure) }

        switch await EndpointHealthCheck.probe(url) {
        case .unreachable(let detail):
            return .rejected(.unreachable(detail: detail))
        case .notTigerDuck:
            return .rejected(.notTigerDuck)
        case .ok:
            return .accepted(url)
        }
    }

    /// Stores an endpoint ``check(_:)`` accepted and returns whether the Keychain took it.
    static func store(_ url: URL) async -> Bool {
        let written = KeychainManager.saveStringReportingSuccess(key: keychainKey, value: url.absoluteString)
        stored.forget()
        if written { await AcademicCalendarStore.shared.endpointDidChange() }
        return written
    }

    /// `@MainActor` for the calendar invalidation below. The only caller is
    /// the Settings screen's reset button, which is already there.
    @MainActor
    static func clearOverride() {
        KeychainManager.delete(key: keychainKey)
        stored.forget()
        AcademicCalendarStore.shared.endpointDidChange()
    }
}

/// A Keychain string kept in memory after its first read, which the notifications given (an
/// unlock, a return to the app) and ``forget()``, called by the value's writers after each change,
/// drop. A read that cannot reach the Keychain, as before the first unlock after a restart, is not
/// kept: a suspended app may get neither notification before its next background request.
nonisolated final class KeychainReadCache: Sendable {
    private struct State {
        /// `nil` until read; `.some(nil)` is a read that found nothing.
        var value: String??
        /// Moved by each ``forget()``, so a read that a change overtook does not keep its value.
        var generation = 0
    }

    private let load: @Sendable () throws -> String?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        load: @escaping @Sendable () throws -> String?,
        forgetOn names: [Notification.Name] = [],
        center: NotificationCenter = .default
    ) {
        self.load = load
        for name in names {
            // Never removed: `[weak self]` makes the observer a no-op once this cache is gone,
            // which for the store's static one is never.
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.forget()
            }
        }
    }

    func value() -> String? {
        let (cached, generation) = state.withLock { ($0.value, $0.generation) }
        if let cached { return cached }
        let loaded: String?
        do { loaded = try load() } catch { return nil }
        state.withLock { state in
            if state.generation == generation { state.value = .some(loaded) }
        }
        return loaded
    }

    func forget() {
        state.withLock { state in
            state.value = nil
            state.generation &+= 1
        }
    }
}

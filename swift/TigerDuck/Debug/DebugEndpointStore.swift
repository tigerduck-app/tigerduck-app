import Foundation

/// Keychain-backed storage for the user-set API endpoint override
/// (Settings → Other settings → API endpoint, and the same screen offered
/// from onboarding's sign-in page). Honoured by every build; the name
/// predates the row leaving the Developer section.
///
/// Lives in Keychain (not UserDefaults) so the override survives an app
/// uninstall + reinstall — useful for repeatedly wiping the app to retest
/// fresh-install flows against a staging or self-hosted backend without
/// having to re-enter the URL after every install. The underlying
/// ``SecureStore`` uses `.whenUnlockedThisDeviceOnly`, so the value stays
/// on the device it was set on and isn't restored via iCloud Keychain.
///
/// See ``PushServerConfig/resolveServerURL()`` for the full resolution
/// chain this override participates in. All write paths funnel through
/// ``PushServerConfig/isOverrideAllowed(_:)`` and
/// ``EndpointHealthCheck/probe(_:)``, so a value that no longer meets the
/// transport rules — or that nothing is serving — cannot be stored.
///
/// Both write paths also call ``AcademicCalendarStore/endpointDidChange()``:
/// the academic calendar is cached with an opaque ETag that says nothing
/// about which backend issued it, so without this the next server's
/// conditional GET can be answered 304 against the previous server's dates.
nonisolated enum DebugEndpointStore {
    /// Internal (not private) so the erase-everything action can name the
    /// one key it deliberately preserves.
    static let keychainKey = "debug_api_endpoint_override"

    enum SetOverrideResult: Equatable {
        case success
        /// Not parseable as a URL with a scheme and a host.
        case malformed
        /// Parsed, but points at a routable address over plain HTTP.
        case insecure
        /// Passed validation, but the health probe found nothing serving.
        case unreachable(detail: String)
        /// Something answered the health probe, but not this backend.
        case notTigerDuck
        case keychainWriteFailed
    }

    /// Returns the stored override URL string, or nil if none is set or
    /// the stored value no longer passes the safety gate (e.g. the
    /// transport rules tightened after the value was saved).
    static func currentOverride() -> String? {
        guard let raw = KeychainManager.loadString(key: keychainKey),
              !raw.isEmpty,
              let url = URL(string: raw),
              PushServerConfig.isOverrideAllowed(url)
        else { return nil }
        return raw
    }

    /// Returns a value that was previously saved but no longer passes
    /// ``PushServerConfig/isOverrideAllowed(_:)`` (e.g. the transport rules
    /// tightened in a later build). Lets the UI explain why the override
    /// the user set last week silently stopped taking effect, instead of
    /// just falling back to the default without a breadcrumb.
    ///
    /// Note this is a *validation* check, not a liveness one: an endpoint
    /// that is merely down still reads as the active override, because
    /// that is what the app is genuinely still trying to talk to.
    static func storedButRejectedOverride() -> String? {
        guard let raw = KeychainManager.loadString(key: keychainKey),
              !raw.isEmpty
        else { return nil }
        if let url = URL(string: raw), PushServerConfig.isOverrideAllowed(url) {
            return nil
        }
        return raw
    }

    /// Validates `value`, probes it, and stores it only if a TigerDuck
    /// backend answered.
    ///
    /// The probe runs **before** the write on purpose: this endpoint is
    /// where every subsequent request goes, including the ones that fetch
    /// the screens the user would need to come back and fix a bad value.
    /// Returns a typed result so the caller can tell a typo from a host
    /// that is simply down from a Keychain failure.
    static func setOverride(_ value: String) async -> SetOverrideResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed), parsed.host != nil else {
            return .malformed
        }
        let url = PushServerConfig.normalize(parsed)
        guard PushServerConfig.isOverrideAllowed(url) else { return .insecure }

        switch await EndpointHealthCheck.probe(url) {
        case .unreachable(let detail):
            return .unreachable(detail: detail)
        case .notTigerDuck:
            return .notTigerDuck
        case .ok:
            break
        }

        let written = KeychainManager.saveStringReportingSuccess(
            key: keychainKey, value: url.absoluteString
        )
        if written { await AcademicCalendarStore.shared.endpointDidChange() }
        return written ? .success : .keychainWriteFailed
    }

    /// `@MainActor` for the calendar invalidation below. The only caller is
    /// the Settings screen's reset button, which is already there.
    @MainActor
    static func clearOverride() {
        KeychainManager.delete(key: keychainKey)
        AcademicCalendarStore.shared.endpointDidChange()
    }
}

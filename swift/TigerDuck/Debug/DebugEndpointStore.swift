import Foundation

/// Keychain-backed API endpoint override, set in Settings → Other settings → API endpoint or on
/// onboarding's sign-in page, and honoured by every build. Keychain, not UserDefaults, so it
/// survives the reinstalls done to retest fresh installs against another backend. ``SecureStore``
/// keeps it `.afterFirstUnlockThisDeviceOnly`: never restored via iCloud Keychain, and readable by
/// a launch behind the lock screen, which would otherwise use the default backend. A value is
/// stored only if ``PushServerConfig/isOverrideAllowed(_:)`` and ``EndpointHealthCheck/probe(_:)``
/// accept it. Set and clear call ``AcademicCalendarStore/endpointDidChange()``: the calendar's ETag
/// does not name its backend, so the next server could answer 304 against the old server's dates.
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

    /// Returns the stored override when it fails ``PushServerConfig/isOverrideAllowed(_:)``, for
    /// example after a later build tightened the transport rules, so the UI can explain why a
    /// saved override stopped taking effect instead of falling back to the default without a word.
    ///
    /// This checks validation, not liveness: an endpoint that is merely down still reads as the
    /// active override, because the app is still trying to talk to it.
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

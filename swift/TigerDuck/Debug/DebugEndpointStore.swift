import Foundation

/// Keychain-backed storage for the user-set API endpoint override
/// (Settings → Other settings → API endpoint). Honoured by every build;
/// the name predates the row leaving the Developer section.
///
/// Lives in Keychain (not UserDefaults) so the override survives an app
/// uninstall + reinstall — useful for repeatedly wiping the app to retest
/// fresh-install flows against a staging or LAN backend without having to
/// re-enter the URL after every install. The underlying ``SecureStore``
/// uses `.whenUnlockedThisDeviceOnly`, so the value stays on the device
/// it was set on and isn't restored via iCloud Keychain.
///
/// See ``PushServerConfig/resolveServerURL()`` for the full resolution
/// chain this override participates in. All write paths funnel through
/// ``PushServerConfig/isOverrideAllowed(_:)``, so an attacker who somehow
/// seeded the Keychain (a restored backup, MDM, etc.) still can't redirect
/// the app to an arbitrary public host.
nonisolated enum DebugEndpointStore {
    private static let keychainKey = "debug_api_endpoint_override"

    enum SetOverrideResult: Equatable {
        case success
        case malformed
        case rejected
        case keychainWriteFailed
    }

    /// Returns the stored override URL string, or nil if none is set or
    /// the stored value no longer passes the safety gate (e.g. the
    /// allowlist tightened after the value was saved).
    static func currentOverride() -> String? {
        guard let raw = KeychainManager.loadString(key: keychainKey),
              !raw.isEmpty,
              let url = URL(string: raw),
              PushServerConfig.isOverrideAllowed(url)
        else { return nil }
        return raw
    }

    /// Returns a value that was previously saved but no longer passes the
    /// allowlist (e.g. ``PushServerConfig/isAllowedPublicHost(_:)`` or
    /// the loopback/RFC1918 gate tightened in a later build). Lets the UI
    /// explain why the override the user set last week silently stopped
    /// taking effect, instead of just falling back to localhost without
    /// a breadcrumb.
    static func storedButRejectedOverride() -> String? {
        guard let raw = KeychainManager.loadString(key: keychainKey),
              !raw.isEmpty
        else { return nil }
        if let url = URL(string: raw), PushServerConfig.isOverrideAllowed(url) {
            return nil
        }
        return raw
    }

    /// Stores `value` after validating it through the same gate as the
    /// UserDefaults override path. Returns a typed result so callers can
    /// distinguish parse errors, allowlist rejection, and Keychain write
    /// failures (which previously all collapsed to a single Bool false and
    /// rendered as "rejected" no matter the actual cause).
    @discardableResult
    static func setOverride(_ value: String) -> SetOverrideResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed) else { return .malformed }
        let url = PushServerConfig.normalize(parsed)
        guard PushServerConfig.isOverrideAllowed(url) else { return .rejected }
        let written = KeychainManager.saveStringReportingSuccess(key: keychainKey, value: url.absoluteString)
        return written ? .success : .keychainWriteFailed
    }

    static func clearOverride() {
        KeychainManager.delete(key: keychainKey)
    }
}

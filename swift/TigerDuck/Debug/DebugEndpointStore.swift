#if DEBUG
import Foundation

/// Keychain-backed storage for the Debug API endpoint override.
///
/// Lives in Keychain (not UserDefaults) so the override survives an app
/// uninstall + reinstall — useful for repeatedly wiping the app to retest
/// fresh-install flows against a staging or LAN backend without having to
/// re-enter the URL after every install. The underlying ``SecureStore``
/// uses `.whenUnlockedThisDeviceOnly`, so the value stays on the device
/// it was set on and isn't restored via iCloud Keychain.
///
/// Resolution priority in ``PushServerConfig/resolveServerURL()`` (Debug
/// builds only):
///   1. This Keychain override
///   2. ``Defaults[.pushServerURLOverride]`` (UserDefaults escape hatch)
///   3. `Secrets.plist["DebugServerURL"]` (per-developer)
///   4. ``AppConstants/fallbackDebugPushServerURL``
///
/// All write paths funnel through ``PushServerConfig/isOverrideAllowed(_:)``,
/// so an attacker who somehow seeded the Keychain (a restored backup,
/// MDM, etc.) still can't redirect the app to an arbitrary public host.
nonisolated enum DebugEndpointStore {
    private static let keychainKey = "debug_api_endpoint_override"

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

    /// Stores `value` after validating it through the same gate as the
    /// UserDefaults override path. Returns true on success, false if the
    /// URL is malformed or fails the allowlist — callers should surface a
    /// validation error to the user in the false case.
    @discardableResult
    static func setOverride(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed) else { return false }
        let url = PushServerConfig.normalize(parsed)
        guard PushServerConfig.isOverrideAllowed(url) else { return false }
        KeychainManager.saveString(key: keychainKey, value: url.absoluteString)
        return true
    }

    static func clearOverride() {
        KeychainManager.delete(key: keychainKey)
    }
}
#endif

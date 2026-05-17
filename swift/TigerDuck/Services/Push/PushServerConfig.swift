import Defaults
import Foundation

/// Cross-platform resolver for the push backend URL + shared secret +
/// `Secrets.plist` helper.
///
/// Extracted from `PushCoordinator` so non-push HTTP clients
/// (e.g. `BulletinAPIClient`, which talks to the same backend for the
/// bulletin board) can resolve the same URL/credentials without
/// importing the iOS-only ActivityKit-coupled coordinator. The
/// behaviour is identical to the previous `PushCoordinator.resolveXxx`
/// surface — this is a pure move.
nonisolated enum PushServerConfig {
    /// Public hosts a Debug override is allowed to target. Staging only —
    /// production is intentionally absent: a Debug binary has
    /// `PushAPNsEnv.resolvedForBuild = "development"` baked in at compile
    /// time, so pointing it at the prod backend creates an apns_env
    /// mismatch the production APNs server would reject anyway. Allowing
    /// it here would let `isOverrideAllowed` pass a URL that
    /// `PushCoordinator.assertEnvConsistency()` then crashes on every
    /// launch.
    ///
    /// Everything else must resolve to loopback or an RFC1918 private
    /// IPv4 (see ``isOverrideAllowed(_:)``). An attacker-supplied override
    /// (via UserDefaults seeding from a compromised backup, MDM, or a
    /// future dev panel) cannot point the app at an arbitrary public
    /// server outside this list. Release builds bypass this gate entirely.
    private static let publicHostAllowlist: Set<String> = [
        "staging.api.tigerduck.app",
    ]

    /// Resolves the backend URL for this build.
    ///
    /// Release builds always return ``AppConstants/productionPushServerURL``.
    ///
    /// Debug builds resolve in priority order:
    ///   1. `Defaults[.pushServerURLOverride]` (UserDefaults escape hatch,
    ///      gated by ``isOverrideAllowed(_:)``)
    ///   2. `Secrets.plist["DebugServerURL"]` (per-developer LAN backend;
    ///      file is gitignored so each contributor sets their own Mac's IP)
    ///   3. ``AppConstants/fallbackDebugPushServerURL`` (Simulator-friendly
    ///      `http://localhost:40000/v2`)
    static func resolveServerURL() -> URL {
        #if DEBUG
        if let override = Defaults[.pushServerURLOverride],
           !override.isEmpty,
           let url = URL(string: override),
           isOverrideAllowed(url) {
            return url
        }
        if let url = readDebugServerURL() {
            return url
        }
        return AppConstants.fallbackDebugPushServerURL
        #else
        return AppConstants.productionPushServerURL
        #endif
    }

    /// Whether `url` may be used as a runtime override.
    ///
    /// Public hosts are exact-matched against ``publicHostAllowlist``;
    /// everything else must be loopback or an RFC1918 private IPv4 literal.
    /// `http://` is allowed only for private/loopback targets — public hosts
    /// must speak HTTPS.
    static func isOverrideAllowed(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        if publicHostAllowlist.contains(host) {
            return url.scheme == "https"
        }
        if host == "localhost" || host == "127.0.0.1" || isPrivateIPv4(host) {
            return url.scheme == "http" || url.scheme == "https"
        }
        return false
    }

    /// True if `host` parses as an RFC1918 private IPv4 literal
    /// (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16). Hostnames, IPv6
    /// literals, and malformed input return false.
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    #if DEBUG
    /// Reads `Secrets.plist["DebugServerURL"]` and runs it through the same
    /// gate as the UserDefaults override path. Mis-filled or template values
    /// (e.g. the literal `http://192.168.X.X:40000/v2` from
    /// `Secrets.example.plist`) return nil so the resolver falls back to
    /// `localhost:40000` instead of returning an unreachable URL that would
    /// either trip `PushCoordinator.assertEnvConsistency()` at launch or, with
    /// assertions disabled, silently let the app talk to an arbitrary host.
    private static func readDebugServerURL() -> URL? {
        guard let dict = secretsPlistDict(),
              let raw = dict["DebugServerURL"] as? String,
              !raw.isEmpty,
              let url = URL(string: raw),
              isOverrideAllowed(url)
        else { return nil }
        return url
    }
    #endif

    /// Read the shared secret from `Secrets.plist` (gitignored) bundled
    /// with the app. Must match the corresponding backend's
    /// `TIGERDUCK_API_SHARED_SECRET` or every write request 401s.
    ///
    /// Resolution order:
    ///   1. Debug builds: `DebugAPIToken` — paired with `DebugServerURL`,
    ///      so each contributor's local backend can have its own secret
    ///      without leaking the production one through dev Macs.
    ///   2. `APIToken` — production secret; also the Debug fallback when
    ///      a contributor leaves `DebugAPIToken` blank (matches the old
    ///      "single shared token" workflow).
    ///   3. Legacy Info.plist `TigerDuckAPIToken` — kept so any CI
    ///      pipeline that still injects there continues to work.
    ///   4. nil — preserves the dev-friendly no-auth path.
    static func resolveSharedSecret() -> String? {
        if let dict = secretsPlistDict() {
            #if DEBUG
            if let value = dict["DebugAPIToken"] as? String, !value.isEmpty {
                return value
            }
            #endif
            if let value = dict["APIToken"] as? String, !value.isEmpty {
                return value
            }
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "TigerDuckAPIToken") as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    static func secretsPlistDict() -> NSDictionary? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") else {
            return nil
        }
        return NSDictionary(contentsOf: url)
    }
}

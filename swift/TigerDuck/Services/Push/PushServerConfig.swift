import Defaults
import Foundation

/// Cross-platform resolver for the push backend URL.
///
/// Also provides the `Secrets.plist` helper used to read the optional
/// `DebugServerURL` LAN-backend override.
///
/// Extracted from `PushCoordinator` so non-push HTTP clients
/// (e.g. `BulletinAPIClient`, which talks to the same backend for the
/// bulletin board) can resolve the same URL/credentials without
/// importing the iOS-only ActivityKit-coupled coordinator. The
/// behaviour is identical to the previous `PushCoordinator.resolveXxx`
/// surface — this is a pure move.
nonisolated enum PushServerConfig {
    /// Public hosts a Debug override is allowed to target. Apex
    /// (`api.tigerduck.app`) plus any `*.api.tigerduck.app` subdomain.
    ///
    /// WARNING: pointing a Debug build at the prod apex still creates an
    /// apns_env mismatch — Debug binaries bake in
    /// `PushAPNsEnv.resolvedForBuild = "development"`, and the production
    /// APNs server rejects sandbox tokens. The bulletin / read-only API
    /// clients don't care about apns_env, so the allowlist is widened
    /// here for read-side testing; push registration on a prod-pointed
    /// Debug build will fail at the server, but the app still launches
    /// (see `PushCoordinator.assertEnvConsistency()`, which now accepts
    /// any host this allowlist accepts so a saved Keychain override
    /// can't brick the next launch).
    ///
    /// Everything else must resolve to loopback or an RFC1918 private
    /// IPv4 (see ``isOverrideAllowed(_:)``). An attacker-supplied override
    /// (via UserDefaults seeding from a compromised backup, MDM, or a
    /// future dev panel) cannot point the app at an arbitrary public
    /// server outside this list. Release builds bypass this gate entirely.
    private static let publicHostExactAllowlist: Set<String> = [
        "api.tigerduck.app",
    ]
    private static let publicHostSuffixAllowlist: [String] = [
        ".api.tigerduck.app",
    ]

    /// Internal so `PushCoordinator.assertEnvConsistency()` can use the
    /// same gate as the runtime override path — keeping the two in sync
    /// avoids the trap where a host the resolver accepts at runtime then
    /// crashes the next launch's assert.
    static func isAllowedPublicHost(_ host: String) -> Bool {
        // DNS is case-insensitive; `URL.host` preserves whatever case the
        // user typed, so normalize before matching to avoid rejecting
        // legitimate input like `API.tigerduck.app`.
        let normalized = host.lowercased()
        if publicHostExactAllowlist.contains(normalized) { return true }
        return publicHostSuffixAllowlist.contains { suffix in
            // host must be longer than the suffix so we don't double-count
            // the apex (e.g. ".api.tigerduck.app" as suffix shouldn't match
            // "api.tigerduck.app" on its own — exact list handles that).
            normalized.count > suffix.count && normalized.hasSuffix(suffix)
        }
    }

    /// Resolves the backend URL for this build.
    ///
    /// Release builds always return ``AppConstants/productionPushServerURL``.
    ///
    /// Debug builds resolve in priority order:
    ///   1. ``DebugEndpointStore/currentOverride()`` (Keychain — set via
    ///      the in-app Developer settings; persists across reinstall)
    ///   2. `Defaults[.pushServerURLOverride]` (UserDefaults escape hatch,
    ///      gated by ``isOverrideAllowed(_:)``)
    ///   3. `Secrets.plist["DebugServerURL"]` (per-developer LAN backend;
    ///      file is gitignored so each contributor sets their own Mac's IP)
    ///   4. ``AppConstants/fallbackDebugPushServerURL`` (Simulator-friendly
    ///      `http://localhost:40000/v3`)
    static func resolveServerURL() -> URL {
        #if DEBUG
        if let raw = DebugEndpointStore.currentOverride(),
           let url = URL(string: raw),
           isOverrideAllowed(url) {
            return normalize(url)
        }
        if let override = Defaults[.pushServerURLOverride],
           !override.isEmpty,
           let url = URL(string: override),
           isOverrideAllowed(url) {
            return normalize(url)
        }
        if let url = readDebugServerURL() {
            return normalize(url)
        }
        return AppConstants.fallbackDebugPushServerURL
        #else
        return AppConstants.productionPushServerURL
        #endif
    }

    /// Whether `url` may be used as a runtime override.
    ///
    /// Public hosts are matched against ``isAllowedPublicHost(_:)`` (apex
    /// + `*.api.tigerduck.app`); everything else must be loopback or an
    /// RFC1918 private IPv4 literal. `http://` is allowed only for
    /// private/loopback targets — public hosts must speak HTTPS.
    static func isOverrideAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if isAllowedPublicHost(host) {
            return url.scheme == "https"
        }
        if host == "localhost" || host == "127.0.0.1" || isPrivateIPv4(host) {
            return url.scheme == "http" || url.scheme == "https"
        }
        return false
    }

    /// Normalizes a candidate override URL so the most common typo —
    /// pasting `https://192.168.X.X:40000/v3` for a LAN dev backend that
    /// doesn't terminate TLS — resolves to a working `http://` URL instead
    /// of failing at handshake time with `WRONG_VERSION_NUMBER`.
    ///
    /// Only loopback and RFC1918 private IPv4 hosts are rewritten. Public
    /// hosts (e.g. `staging.api.tigerduck.app`) are returned unchanged so
    /// the allowlist's HTTPS requirement still bites.
    static func normalize(_ url: URL) -> URL {
        guard url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || isPrivateIPv4(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "http"
        if let rewritten = components.url {
            return rewritten
        }
        // Should be unreachable: we only flipped the scheme on a URL that
        // already round-tripped through URLComponents above. If it ever
        // fires, returning `url` would silently re-enable the
        // WRONG_VERSION_NUMBER handshake failure this helper exists to
        // prevent — log loudly so we notice in Sentry.
        assertionFailure("PushServerConfig.normalize: URLComponents.url returned nil after scheme rewrite for \(url.absoluteString)")
        AppLogger.captureError(
            PushServerConfigError.schemeRewriteProducedNilURL,
            context: ["originalURL": url.absoluteString]
        )
        return url
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
    /// (e.g. the literal `http://192.168.X.X:40000/v3` from
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

    static func secretsPlistDict() -> NSDictionary? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") else {
            // Missing file is the intentional dev path — contributors who
            // don't need a backend secret simply don't ship `Secrets.plist`.
            // Stay silent here so we don't spam Sentry on every cold start.
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            )
            return parsed as? NSDictionary
        } catch {
            // File exists but can't be parsed (corrupt, wrong root type,
            // wrong format). In Release this previously fell through to a
            // nil shared secret and every authed push call 401'd with no
            // breadcrumb — log so the failure is diagnosable in Sentry.
            AppLogger.captureError(error, context: ["phase": "secretsPlist.parse"])
            return nil
        }
    }
}

private enum PushServerConfigError: Error {
    case schemeRewriteProducedNilURL
}

import Defaults
import Foundation

/// Cross-platform resolver for the push backend URL, plus the
/// `Secrets.plist` helper that reads the optional `DebugServerURL` LAN
/// backend override.
///
/// Kept apart from `PushCoordinator` so other clients of the same backend,
/// such as `BulletinAPIClient`, can resolve its URL and credentials without
/// importing the iOS-only, ActivityKit-coupled coordinator.
nonisolated enum PushServerConfig {

    /// Resolves the backend URL for this build. Every build first honours
    /// ``DebugEndpointStore/currentOverride()``, a Keychain value set in
    /// Settings > Other settings > API endpoint that survives reinstall.
    /// Without one, Release returns ``AppConstants/productionPushServerURL``
    /// and Debug tries `Defaults[.pushServerURLOverride]`, then the gitignored
    /// per-developer LAN URL in `Secrets.plist["DebugServerURL"]`, then the
    /// Simulator-friendly ``AppConstants/fallbackDebugPushServerURL``. The
    /// Keychain and Defaults values must pass ``isOverrideAllowed(_:)``.
    static func resolveServerURL() -> URL {
        if let raw = DebugEndpointStore.currentOverride(),
           let url = URL(string: raw),
           isOverrideAllowed(url) {
            return normalize(url)
        }
        #if DEBUG
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

    /// Whether `url` may be used as a runtime override. The backend is open
    /// source and self-hostable, so any host is allowed; only transport is
    /// checked. ``isPrivateOrLoopbackHost(_:)`` hosts may use `http://`, as LAN
    /// and Simulator backends rarely have TLS and the traffic stays local.
    /// Every other host needs `https://`, because requests carry the
    /// `AuthTokenManager` Bearer token. With no host allowlist, a Keychain
    /// value seeded by a backup or MDM can redirect the app.
    /// See docs/decisions/0022-self-hosted-endpoint-override.md.
    static func isOverrideAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return false }
        if let port = url.port, !(1...65535).contains(port) { return false }
        if isPrivateOrLoopbackHost(host) { return true }
        return scheme == "https"
    }

    /// Normalizes a candidate override URL so the most common typo —
    /// pasting `https://192.168.X.X:40000/v3` for a LAN dev backend that
    /// doesn't terminate TLS — resolves to a working `http://` URL instead
    /// of failing at handshake time with `WRONG_VERSION_NUMBER`.
    ///
    /// Only private / loopback / link-local hosts are rewritten. Public
    /// hosts are returned unchanged so ``isOverrideAllowed(_:)``'s HTTPS
    /// requirement still bites.
    static func normalize(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              isPrivateOrLoopbackHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "http"
        if let rewritten = components.url {
            return rewritten
        }
        // Should be unreachable: only the scheme changed on a URL that
        // URLComponents already parsed. Returning `url` revives the handshake
        // failure this helper prevents, so assert and report it to Sentry.
        assertionFailure("PushServerConfig.normalize: URLComponents.url returned nil after scheme rewrite for \(url.absoluteString)")
        AppLogger.captureError(
            PushServerConfigError.schemeRewriteProducedNilURL,
            context: ["originalURL": url.absoluteString]
        )
        return url
    }

    // MARK: - Host classification

    /// True when `host` cannot be routed off the local network, and so may
    /// be reached over plain HTTP: `localhost` and RFC 6761 `*.localhost`,
    /// IPv4 loopback, RFC 1918 and link-local, IPv6 `::1`, `fc00::/7` and
    /// `fe80::/10`. IPv4-mapped forms such as `::ffff:192.168.1.5` are judged
    /// by their IPv4 address, not waved through.
    ///
    /// Excluded: CGNAT `100.64.0.0/10`, which the carrier routes, and `*.local`
    /// mDNS names, which are names rather than IP ranges; both need HTTPS.
    static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
        // `URL.host` strips the brackets from `[::1]`, but callers that
        // hand us a raw authority string may not have.
        let bare = normalized.hasPrefix("[") && normalized.hasSuffix("]")
            ? String(normalized.dropFirst().dropLast())
            : normalized
        if let octets = parseIPv4(bare) { return isPrivateIPv4(octets: octets) }
        if bare.contains(":") { return isPrivateIPv6(bare) }
        return false
    }

    /// True if `host` parses as a private IPv4 literal — RFC1918
    /// (10/8, 172.16/12, 192.168/16), loopback (127/8), or link-local
    /// (169.254/16). Hostnames, IPv6 literals, and malformed input
    /// return false.
    static func isPrivateIPv4(_ host: String) -> Bool {
        guard let octets = parseIPv4(host) else { return false }
        return isPrivateIPv4(octets: octets)
    }

    private static func isPrivateIPv4(octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (127, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    /// Strict dotted-quad parse: exactly four decimal octets in 0...255
    /// with no leading zeros. Leading zeros are rejected because some
    /// resolvers read `0192.168.1.5` as octal, which would let a crafted
    /// literal read as private here and resolve somewhere else entirely.
    private static func parseIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), String(value) == part, (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    /// Classifies an IPv6 literal. Handles the `::` compressed form and
    /// the IPv4-mapped/`::ffff:` tail by delegating the embedded dotted
    /// quad to the IPv4 rules.
    private static func isPrivateIPv6(_ host: String) -> Bool {
        // Drop any zone id (`fe80::1%en0`) before parsing.
        let withoutZone = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard let bytes = parseIPv6(withoutZone), bytes.count == 16 else { return false }

        // ::1 — loopback.
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d):
        // judge by the embedded IPv4 address, not by the v6 wrapper.
        let firstTen = bytes.prefix(10)
        if firstTen.allSatisfy({ $0 == 0 }) {
            let isMapped = bytes[10] == 0xff && bytes[11] == 0xff
            let isCompatible = bytes[10] == 0 && bytes[11] == 0
            if isMapped || isCompatible {
                return isPrivateIPv4(octets: [Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15])])
            }
        }
        // fc00::/7 — unique local.
        if bytes[0] & 0xfe == 0xfc { return true }
        // fe80::/10 — link local.
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        return false
    }

    /// Parses an IPv6 literal into 16 bytes via the system resolver, which
    /// is the same parser URLSession will use — hand-rolling the `::`
    /// expansion risks classifying an address differently from the stack
    /// that actually dials it.
    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    // MARK: - Secrets.plist

    #if DEBUG
    /// Reads `Secrets.plist["DebugServerURL"]` and runs it through the same
    /// gate as the UserDefaults override path. Mis-filled or template values
    /// (e.g. the literal `http://192.168.X.X:40000/v3` from
    /// `Secrets.example.plist`) return nil so the resolver falls back to
    /// `localhost:40000` instead of returning an unreachable URL.
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
            // The file exists but does not parse (corrupt, wrong root type or
            // format). Report it so the failure is diagnosable in Sentry.
            AppLogger.captureError(error, context: ["phase": "secretsPlist.parse"])
            return nil
        }
    }
}

private enum PushServerConfigError: Error {
    case schemeRewriteProducedNilURL
}

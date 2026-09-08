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
/// importing the iOS-only ActivityKit-coupled coordinator.
nonisolated enum PushServerConfig {

    /// Resolves the backend URL for this build.
    ///
    /// Every build honours ``DebugEndpointStore/currentOverride()`` first
    /// (Keychain — set via Settings → Other settings → API endpoint;
    /// persists across reinstall, gated by ``isOverrideAllowed(_:)``).
    ///
    /// Without one, Release returns ``AppConstants/productionPushServerURL``
    /// and Debug resolves in priority order:
    ///   1. `Defaults[.pushServerURLOverride]` (UserDefaults escape hatch,
    ///      gated by ``isOverrideAllowed(_:)``)
    ///   2. `Secrets.plist["DebugServerURL"]` (per-developer LAN backend;
    ///      file is gitignored so each contributor sets their own Mac's IP)
    ///   3. ``AppConstants/fallbackDebugPushServerURL`` (Simulator-friendly
    ///      `http://localhost:40000/v3`)
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

    /// Whether `url` may be used as a runtime override.
    ///
    /// TigerDuck's backend is open source and self-hostable, so the host is
    /// deliberately **not** restricted to an allowlist — anyone may point
    /// the app at their own deployment. What is enforced is transport:
    ///
    /// - **Private / loopback / link-local addresses** (see
    ///   ``isPrivateOrLoopbackHost(_:)``) accept `http://` as well as
    ///   `https://`. A backend on your own LAN or in the Simulator
    ///   typically terminates no TLS, and the traffic never leaves the
    ///   local link, so requiring a certificate there would block the
    ///   common self-hosting case for no real gain.
    /// - **Everything else** — public IP literals *and* hostnames — must
    ///   speak `https://`. These requests carry a Bearer token
    ///   (`AuthTokenManager`), and cleartext to a routable address puts it
    ///   on the wire for anyone on the path.
    ///
    /// Note the deliberate tradeoff this replaced: the previous
    /// `*.api.tigerduck.app` allowlist also meant a Keychain value seeded
    /// by a restored backup or MDM could not redirect the app anywhere
    /// interesting. That mitigation is gone by design — self-hosting
    /// requires it — and the remaining defence is the HTTPS floor plus the
    /// fact that ``DebugEndpointStore/setOverride(_:)`` only writes an
    /// endpoint that answered a TigerDuck health probe.
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

    // MARK: - Host classification

    /// True when `host` is an address that cannot be routed off the local
    /// network, and so may be talked to over plain HTTP.
    ///
    /// Covers `localhost` (and RFC 6761's `*.localhost`), IPv4 loopback /
    /// RFC1918 / link-local, and the IPv6 equivalents — loopback `::1`,
    /// unique-local `fc00::/7`, link-local `fe80::/10`, plus IPv4-mapped
    /// forms like `::ffff:192.168.1.5`, which resolve to an IPv4 address
    /// and must be classified by that address rather than waved through.
    ///
    /// Deliberately excluded: `100.64.0.0/10` (CGNAT) is routable by the
    /// carrier, and `*.local` mDNS names, which are link-local in practice
    /// but are names rather than the IP ranges this gate is specified in
    /// terms of. A backend reached by an mDNS name therefore needs HTTPS.
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

import Defaults
import Foundation

///
nonisolated enum PushServerConfig {

    static func resolveServerURL() -> URL {
        #if DEBUG
        let debugEndpoints = [Defaults[.pushServerURLOverride], secretsPlistDict()?["DebugServerURL"] as? String]
        #else
        let debugEndpoints: [String?] = []
        #endif
        return resolveServerURL(candidates: [DebugEndpointStore.currentOverride()] + debugEndpoints)
    }

    /// The first candidate the override gate allows, normalized; production when none does.
    static func resolveServerURL(candidates: [String?]) -> URL {
        for case let raw? in candidates {
            if let url = URL(string: raw), isOverrideAllowed(url) {
                return normalize(url)
            }
        }
        return AppConstants.productionPushServerURL
    }

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

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let withoutZone = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard let bytes = parseIPv6(withoutZone), bytes.count == 16 else { return false }

        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        let firstTen = bytes.prefix(10)
        if firstTen.allSatisfy({ $0 == 0 }) {
            let isMapped = bytes[10] == 0xff && bytes[11] == 0xff
            let isCompatible = bytes[10] == 0 && bytes[11] == 0
            if isMapped || isCompatible {
                return isPrivateIPv4(octets: [Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15])])
            }
        }
        if bytes[0] & 0xfe == 0xfc { return true }
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

    static func secretsPlistDict() -> NSDictionary? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            )
            return parsed as? NSDictionary
        } catch {
            AppLogger.captureError(error, context: ["phase": "secretsPlist.parse"])
            return nil
        }
    }
}

private enum PushServerConfigError: Error {
    case schemeRewriteProducedNilURL
}

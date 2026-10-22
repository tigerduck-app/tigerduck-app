import Defaults
import Foundation

nonisolated enum PushServerConfig {

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

    static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
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

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    #if DEBUG
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

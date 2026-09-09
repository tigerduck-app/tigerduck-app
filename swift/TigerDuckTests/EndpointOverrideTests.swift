import Foundation
import Testing

@testable import TigerDuck

/// The endpoint gate lets anyone point the app at their own backend, so the
/// only thing standing between a Bearer token and the open wire is the
/// "public addresses must be HTTPS" rule. These pin both halves: what counts
/// as private (and so may use cleartext), and what does not.
@Suite("API endpoint override")
struct EndpointOverrideTests {

    // MARK: - Transport rule

    @Test("public hosts are accepted over https, with no allowlist")
    func publicHostsOverHTTPS() {
        #expect(PushServerConfig.isOverrideAllowed(URL(string: "https://api.tigerduck.app/v3")!))
        #expect(PushServerConfig.isOverrideAllowed(URL(string: "https://tigerduck.my-nas.net/v3")!))
        #expect(PushServerConfig.isOverrideAllowed(URL(string: "https://8.8.8.8/v3")!))
    }

    @Test("public hosts are rejected over cleartext")
    func publicHostsOverHTTP() {
        #expect(!PushServerConfig.isOverrideAllowed(URL(string: "http://api.tigerduck.app/v3")!))
        #expect(!PushServerConfig.isOverrideAllowed(URL(string: "http://tigerduck.my-nas.net/v3")!))
        #expect(!PushServerConfig.isOverrideAllowed(URL(string: "http://8.8.8.8/v3")!))
    }

    @Test("private addresses may use either scheme")
    func privateHostsEitherScheme() {
        #expect(PushServerConfig.isOverrideAllowed(URL(string: "http://192.168.1.5:40000/v3")!))
        #expect(PushServerConfig.isOverrideAllowed(URL(string: "https://192.168.1.5:40000/v3")!))
        #expect(PushServerConfig.isOverrideAllowed(URL(string: "http://localhost:40000/v3")!))
    }

    @Test("non-http schemes and hostless URLs are rejected")
    func malformed() {
        #expect(!PushServerConfig.isOverrideAllowed(URL(string: "ftp://example.com")!))
        #expect(!PushServerConfig.isOverrideAllowed(URL(string: "file:///etc/hosts")!))
    }

    @Test("https to a private host is rewritten to http")
    func normalizeRewritesPrivate() {
        let rewritten = PushServerConfig.normalize(URL(string: "https://192.168.1.5:40000/v3")!)
        #expect(rewritten.absoluteString == "http://192.168.1.5:40000/v3")
    }

    @Test("public hosts are never rewritten, so the https floor still bites")
    func normalizeLeavesPublicAlone() {
        let url = URL(string: "https://api.tigerduck.app/v3")!
        #expect(PushServerConfig.normalize(url).absoluteString == url.absoluteString)
    }

    // MARK: - Host classification

    @Test("rfc1918, loopback and link-local v4 are private")
    func privateIPv4() {
        for host in [
            "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1",
            "127.0.0.1", "127.1.2.3", "169.254.10.1", "localhost", "db.localhost",
        ] {
            #expect(PushServerConfig.isPrivateOrLoopbackHost(host), "\(host) should be private")
        }
    }

    @Test("routable v4 ranges are not private")
    func routableIPv4() {
        // 172.32 is outside the /12; 100.64 is CGNAT, which the carrier routes.
        for host in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.64.0.1", "193.168.0.1"] {
            #expect(!PushServerConfig.isPrivateOrLoopbackHost(host), "\(host) should not be private")
        }
    }

    @Test("leading-zero octets are rejected rather than read as octal")
    func leadingZeroOctets() {
        // Some resolvers read 0192 as octal and land somewhere else entirely.
        #expect(!PushServerConfig.isPrivateOrLoopbackHost("0192.168.1.5"))
    }

    @Test("v6 loopback, unique-local and link-local are private")
    func privateIPv6() {
        for host in ["::1", "[::1]", "fd00::1", "fc00::1", "fe80::1", "fe80::1%en0"] {
            #expect(PushServerConfig.isPrivateOrLoopbackHost(host), "\(host) should be private")
        }
    }

    @Test("routable v6 is not private")
    func routableIPv6() {
        for host in ["2001:db8::1", "[2606:4700:4700::1111]", "fec0::1"] {
            #expect(!PushServerConfig.isPrivateOrLoopbackHost(host), "\(host) should not be private")
        }
    }

    @Test("ipv4-mapped v6 is judged by the embedded address")
    func mappedIPv6() {
        #expect(PushServerConfig.isPrivateOrLoopbackHost("::ffff:192.168.1.5"))
        #expect(!PushServerConfig.isPrivateOrLoopbackHost("::ffff:8.8.8.8"))
    }

    // MARK: - Health URL

    /// `/health` is a sibling of the version prefix, not a child of it.
    /// Getting this wrong makes every save fail with "not a TigerDuck
    /// backend" against a perfectly healthy server.
    @Test("health url replaces the version segment rather than appending")
    func healthURL() {
        func health(_ base: String) -> String? {
            EndpointHealthCheck.healthURL(for: URL(string: base)!)?.absoluteString
        }
        #expect(health("https://api.tigerduck.app/v3") == "https://api.tigerduck.app/health")
        #expect(health("https://api.tigerduck.app/v3/") == "https://api.tigerduck.app/health")
        #expect(health("https://example.com/tigerduck/v3") == "https://example.com/tigerduck/health")
        #expect(health("https://example.com") == "https://example.com/health")
        #expect(health("http://192.168.1.5:40000/v3") == "http://192.168.1.5:40000/health")
        #expect(health("https://example.com/v3?x=1#y") == "https://example.com/health")
    }
}

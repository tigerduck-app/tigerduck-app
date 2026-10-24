#if os(iOS)
import Foundation
import Security
import Testing
@testable import TigerDuck

/// The A4 rules on chains NTUST served, evaluated by system trust at the capture date.
struct TLSPinEnforcementTests {
    typealias F = TLSPinFixtures

    static let host = "www.ntust.edu.tw"
    static let wwwChain = TLSPinningDelegateTests.wwwChain
    static let date = TLSPinningDelegateTests.capturedDate

    /// A document that moves the `ntust` set off every certificate NTUST serves.
    static func movedPins(promptRoots: [String], serial: Int64 = 100) -> Data {
        F.envelope(F.payload(
            serial: serial,
            sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])],
            promptRoots: promptRoots
        ))
    }

    private func chain() throws -> [SecCertificate] {
        try #require(F.evaluatedChain(Self.wwwChain, host: Self.host, at: Self.date))
    }

    private func engine(document: Data? = nil, defaults: UserDefaults = F.defaults(), buildNumber: String = "100") -> TLSPinEngine {
        let engine = F.engine(defaults: defaults, buildNumber: buildNumber, now: Self.date)
        if let document { engine.acceptDocument(document) }
        return engine
    }

    @Test("A chain with a pinned CA passes")
    func aMatchPasses() throws {
        #expect(engine().evaluate(host: Self.host, chain: try chain()) == .allowed)
    }

    @Test("A mismatch whose anchor is a listed public root is reported for a prompt")
    func aPublicRootMismatchIsReported() async throws {
        let engine = engine(document: Self.movedPins(promptRoots: [F.globalRootSPKI]))
        let reports = TLSPinReports()
        reports.install(on: engine)
        let chain = try chain()

        #expect(engine.evaluate(host: Self.host, chain: chain) == .refused(setID: "ntust"))
        #expect(await engine.resolveRefusal(host: Self.host, chain: chain) == false)

        let mismatch = try #require(reports.all.first)
        #expect(reports.all.count == 1)
        #expect(mismatch.setID == "ntust")
        #expect(mismatch.host == Self.host)
        #expect(mismatch.domains == ["ntust.edu.tw"])
        #expect(mismatch.issuerOrganization == "TAIWAN-CA")
        #expect(mismatch.certificates.count == 3)
        let leaf = try #require(mismatch.certificates.first)
        #expect(leaf.issuer == "TWCA Secure SSL Certification Authority")
        #expect(leaf.notBefore == ISO8601DateFormatter().date(from: "2026-01-21T05:27:05Z"))
        #expect(leaf.notAfter == ISO8601DateFormatter().date(from: "2027-02-18T15:59:59Z"))
        #expect(leaf.sha256Fingerprint.hasPrefix("F8 E5 97 C6 AA 14"))
        #expect(mismatch.certificates.last?.name == "TWCA Global Root CA")
        #expect(mismatch.acceptedSPKIs == [F.ntustLeafSPKI, F.secureSSLCASPKI])
        #expect(engine.isRefusing(host: Self.host))
    }

    @Test("A mismatch whose anchor is not a listed root fails with no prompt")
    func anUnlistedRootIsNotReported() async throws {
        let engine = engine(document: Self.movedPins(promptRoots: [F.unknownSPKI]))
        let reports = TLSPinReports()
        reports.install(on: engine)
        #expect(await engine.resolveRefusal(host: Self.host, chain: try chain()) == false)
        #expect(reports.all.isEmpty)
    }

    @Test("A mismatch with no document fails with no prompt")
    func noDocumentNoPrompt() async throws {
        let engine = F.engine(builtIn: [
            TLSPinSet(id: "ntust", domains: [.init(name: "ntust.edu.tw", includeSubdomains: true)],
                      pins: [F.unknownSPKI], expiresAt: .distantFuture),
        ], now: Self.date)
        let reports = TLSPinReports()
        reports.install(on: engine)
        #expect(await engine.resolveRefusal(host: Self.host, chain: try chain()) == false)
        #expect(reports.all.isEmpty)
    }

    @Test("A refusal fetches the document once per set per launch")
    func oneRefreshPerSetPerLaunch() async throws {
        let engine = engine(document: Self.movedPins(promptRoots: []))
        let refreshes = Counter()
        TLSPinReports().install(on: engine, refresh: { await refreshes.increment() })
        let chain = try chain()
        _ = await engine.resolveRefusal(host: Self.host, chain: chain)
        _ = await engine.resolveRefusal(host: "moodle2.ntust.edu.tw", chain: chain)
        #expect(await refreshes.value == 1)
    }

    @Test("A refresh that brings matching pins lets the chain through with no prompt")
    func aRefreshFixesTheChainSilently() async throws {
        let engine = engine(document: Self.movedPins(promptRoots: [F.globalRootSPKI]))
        let fixed = F.envelope(F.payload(
            serial: 101, sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.secureSSLCASPKI])]
        ))
        let reports = TLSPinReports()
        reports.install(on: engine, refresh: { _ = engine.acceptDocument(fixed) })
        #expect(await engine.resolveRefusal(host: Self.host, chain: try chain()))
        #expect(reports.all.isEmpty)
        #expect(!engine.isRefusing(host: Self.host))
    }

    @Test("An accepted chain passes, and the acceptance never stores the root")
    func anAcceptedChainPasses() async throws {
        let defaults = F.defaults()
        let engine = engine(document: Self.movedPins(promptRoots: [F.globalRootSPKI]), defaults: defaults)
        let reports = TLSPinReports()
        reports.install(on: engine)
        let chain = try chain()
        _ = await engine.resolveRefusal(host: Self.host, chain: chain)
        engine.accept(try #require(reports.all.first))

        #expect(engine.evaluate(host: Self.host, chain: chain) == .allowed)
        #expect(!engine.isRefusing(host: Self.host))
        let stored = try #require(engine.acceptances.first)
        #expect(!stored.spkis.contains(F.globalRootSPKI))
        #expect(stored.buildNumber == "100")
        #expect(self.engine(defaults: defaults).evaluate(host: Self.host, chain: chain) == .allowed)
    }

    @Test("An acceptance made under another build is dropped")
    func aBuildChangeDropsAcceptances() async throws {
        let defaults = F.defaults()
        let document = Self.movedPins(promptRoots: [F.globalRootSPKI])
        let before = engine(document: document, defaults: defaults)
        let reports = TLSPinReports()
        reports.install(on: before)
        let chain = try chain()
        _ = await before.resolveRefusal(host: Self.host, chain: chain)
        before.accept(try #require(reports.all.first))

        let after = engine(defaults: defaults, buildNumber: "101")
        #expect(after.acceptances.isEmpty)
        #expect(after.evaluate(host: Self.host, chain: chain) == .refused(setID: "ntust"))
    }

    @Test("A chain with no intermediate stores its leaf only")
    func aLeafAndRootChainStoresTheLeaf() async throws {
        let engine = F.engine(builtIn: [
            TLSPinSet(id: "test", domains: [.init(name: "localhost", includeSubdomains: false)],
                      pins: [F.unknownSPKI], expiresAt: .distantFuture),
        ])
        let rootSPKI = try #require(TLSSPKI.sha256Base64(of: F.testRoot))
        engine.acceptDocument(F.envelope(F.payload(promptRoots: [rootSPKI])))
        let reports = TLSPinReports()
        reports.install(on: engine)
        _ = await engine.resolveRefusal(host: "localhost", chain: [F.testLeaf, F.testRoot])
        let leafSPKI = try #require(TLSSPKI.sha256Base64(of: F.testLeaf))
        #expect(reports.all.first?.acceptedSPKIs == [leafSPKI])
    }

    @Test("Past its expiry a set stops enforcing")
    func anExpiredSetAllows() throws {
        let engine = F.engine(builtIn: [
            TLSPinSet(id: "ntust", domains: [.init(name: "ntust.edu.tw", includeSubdomains: true)],
                      pins: [F.unknownSPKI], expiresAt: Self.date.addingTimeInterval(-1)),
        ], now: Self.date)
        #expect(engine.evaluate(host: Self.host, chain: try chain()) == .expired)
    }
}

/// `TLSPinningDelegate` answering a server-trust challenge.
struct TLSPinningDelegateChallengeTests {
    typealias F = TLSPinFixtures
    typealias E = TLSPinEnforcementTests

    private func disposition(
        _ engine: TLSPinEngine, host: String = E.host, chain: [[UInt8]] = E.wwwChain
    ) async throws -> URLSession.AuthChallengeDisposition {
        let trust = try #require(F.trust(chain, host: host, at: E.date))
        let challenge = URLAuthenticationChallenge(
            protectionSpace: ServerTrustSpace(host: host, trust: trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: NoChallengeSender()
        )
        let delegate = TLSPinningDelegate(engine: engine)
        return await withCheckedContinuation { continuation in
            delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }
    }

    private func engine(document: Data? = nil) -> TLSPinEngine {
        let engine = F.engine(now: E.date)
        if let document { engine.acceptDocument(document) }
        return engine
    }

    @Test("A pinned CA in the chain uses the credential")
    func aMatchUsesTheCredential() async throws {
        #expect(try await disposition(engine()) == .useCredential)
    }

    @Test("A host outside the pin sets gets the default handling")
    func anUnpinnedHostIsDefault() async throws {
        #expect(try await disposition(engine(), host: "example.com") == .performDefaultHandling)
    }

    @Test("A chain system trust rejects is cancelled with no prompt")
    func aSystemInvalidChainIsCancelled() async throws {
        let engine = engine(document: E.movedPins(promptRoots: [F.globalRootSPKI]))
        let reports = TLSPinReports()
        reports.install(on: engine)
        #expect(try await disposition(engine, host: "a.b.ntust.edu.tw") == .cancelAuthenticationChallenge)
        #expect(reports.all.isEmpty)
    }

    @Test("An eligible mismatch is cancelled and reported")
    func anEligibleMismatchIsReported() async throws {
        let engine = engine(document: E.movedPins(promptRoots: [F.globalRootSPKI]))
        let reports = TLSPinReports()
        reports.install(on: engine)
        #expect(try await disposition(engine) == .cancelAuthenticationChallenge)
        #expect(reports.all.map(\.setID) == ["ntust"])
    }

    @Test("A mismatch the refresh fixes uses the credential for the same request")
    func theChallengeWaitsForTheRefresh() async throws {
        let engine = engine(document: E.movedPins(promptRoots: [F.globalRootSPKI]))
        let fixed = F.envelope(F.payload(serial: 101))
        let reports = TLSPinReports()
        reports.install(on: engine, refresh: { _ = engine.acceptDocument(fixed) })
        #expect(try await disposition(engine) == .useCredential)
        #expect(reports.all.isEmpty)
    }

    @Test("CredentialPostDelegate forwards server trust to the shared pinning delegate")
    func credentialPostForwards() async throws {
        let trust = try #require(F.trust(E.wwwChain, host: "a.b.ntust.edu.tw", at: E.date))
        let challenge = URLAuthenticationChallenge(
            protectionSpace: ServerTrustSpace(host: "a.b.ntust.edu.tw", trust: trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: NoChallengeSender()
        )
        let task = URLSession.shared.dataTask(with: URL(string: "https://a.b.ntust.edu.tw")!)
        let result = await withCheckedContinuation { continuation in
            CredentialPostDelegate().urlSession(URLSession.shared, task: task, didReceive: challenge) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }
        #expect(result == .cancelAuthenticationChallenge)
    }
}

final class ServerTrustSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust) {
        self.trust = trust
        super.init(
            host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

final class NoChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
#endif

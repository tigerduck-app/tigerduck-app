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
        #expect(mismatch.chainSPKIs == [F.ntustLeafSPKI, F.secureSSLCASPKI, F.globalRootSPKI])
        #expect(mismatch.anchorSPKI == F.globalRootSPKI)
        #expect(engine.isRefusing(host: Self.host))
        #expect(engine.isPromptable(mismatch))
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

    @Test("A chain whose leaf and intermediates have no key the app reads gets no prompt")
    func noReadableKeyNoPrompt() async throws {
        let leaf = try #require(SecCertificateCreateWithData(nil, F.p521DER as CFData))
        let rootSPKI = try #require(TLSSPKI.sha256Base64(of: F.testRoot))
        let engine = engine(document: Self.movedPins(promptRoots: [rootSPKI]))
        let reports = TLSPinReports()
        reports.install(on: engine)
        #expect(await engine.resolveRefusal(host: Self.host, chain: [leaf, F.testRoot]) == false)
        #expect(reports.all.isEmpty)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = TLSPinEnforcementTests.date
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    @Test("A refetch that failed, as in a network blip, may be tried again 30 seconds later")
    func aFailedRefreshIsTriedAgainLater() async throws {
        let clock = Clock()
        let engine = TLSPinEngine(
            builtIn: TLSPinTable.builtIn, baselineSerial: 0, keys: F.keys,
            defaults: F.defaults(), buildNumber: "100", clock: { clock.now }
        )
        engine.acceptDocument(Self.movedPins(promptRoots: []))
        let attempts = Counter()
        engine.install(refresh: { await attempts.increment(); return false }, report: nil)
        let chain = try chain()

        _ = await engine.resolveRefusal(host: Self.host, chain: chain)
        clock.advance(29)
        _ = await engine.resolveRefusal(host: Self.host, chain: chain)
        #expect(await attempts.value == 1)
        clock.advance(2)
        _ = await engine.resolveRefusal(host: Self.host, chain: chain)
        #expect(await attempts.value == 2)
    }

    @Test("With no stored document, as before onboarding, a refusal fetches one and its pins let the sign-in through")
    @MainActor
    func aRefusalBeforeOnboardingFetches() async throws {
        let stale = TLSPinSet(
            id: "ntust", domains: [.init(name: "ntust.edu.tw", includeSubdomains: true)],
            pins: [F.unknownSPKI], expiresAt: .distantFuture
        )
        let engine = F.engine(builtIn: [stale], now: Self.date)
        let server = TLSPinDocumentFetcherTests.Server()
        server.body = F.envelope(F.payload(
            serial: 101, sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.secureSSLCASPKI])]
        ))
        engine.installAppHooks(fetcher: TLSPinDocumentFetcher(
            engine: engine, send: { try server.answer($0) }, clock: { Self.date }
        ))
        let chain = try chain()

        #expect(await engine.resolveRefusal(host: Self.host, chain: chain))
        #expect(server.requests.count == 1)
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

    @Test("Refusals at the same time wait for one refresh and all pass once it fixes the pins")
    func concurrentRefusalsShareOneRefresh() async throws {
        let engine = engine(document: Self.movedPins(promptRoots: [F.globalRootSPKI]))
        let fixed = F.envelope(F.payload(serial: 101))
        let refreshes = Counter()
        let reports = TLSPinReports()
        reports.install(on: engine, refresh: {
            await refreshes.increment()
            try? await Task.sleep(for: .milliseconds(200))
            _ = engine.acceptDocument(fixed)
        })
        let chain = try chain()
        async let first = engine.resolveRefusal(host: Self.host, chain: chain)
        async let second = engine.resolveRefusal(host: "moodle2.ntust.edu.tw", chain: chain)
        async let third = engine.resolveRefusal(host: "i.ntust.edu.tw", chain: chain)
        let results = await [first, second, third]
        #expect(results == [true, true, true])
        #expect(await refreshes.value == 1)
        #expect(reports.all.isEmpty)
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

    @Test("Accepting the same chain twice stores its SPKIs once")
    func acceptancesAreDeduplicated() {
        let engine = F.engine(document: F.promptRootsDocument)
        let mismatch = TLSPinMismatchQueueTests.mismatch()
        engine.accept(mismatch)
        engine.accept(mismatch)
        #expect(engine.acceptances.count == 1)
        #expect(engine.acceptances.first?.spkis == mismatch.acceptedSPKIs)
    }

    /// Sign-out clears the account's files and settings; acceptances are kept apart from both.
    @Test("Signing out keeps acceptances")
    func signOutKeepsAcceptances() throws {
        let defaults = F.defaults()
        F.engine(defaults: defaults, document: F.promptRootsDocument).accept(TLSPinMismatchQueueTests.mismatch())
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        DataCache(cacheDir: root.appending(path: "cache"), persistentDir: root.appending(path: "persistent"))
            .clearUserScopedData()
        #expect(F.engine(defaults: defaults).acceptances.count == 1)
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

    @Test("A chain of one certificate is never offered for a prompt")
    func aSingleCertificateChainIsNotEligible() async throws {
        let engine = F.engine(builtIn: [
            TLSPinSet(id: "test", domains: [.init(name: "localhost", includeSubdomains: false)],
                      pins: [F.unknownSPKI], expiresAt: .distantFuture),
        ])
        let rootSPKI = try #require(TLSSPKI.sha256Base64(of: F.testRoot))
        engine.acceptDocument(F.envelope(F.payload(promptRoots: [rootSPKI])))
        let reports = TLSPinReports()
        reports.install(on: engine)
        #expect(await engine.resolveRefusal(host: "localhost", chain: [F.testRoot]) == false)
        #expect(reports.all.isEmpty)
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

    @Test("A refresh that fails or times out still completes the challenge, refused, once", arguments: [
        URLError(.timedOut), URLError(.notConnectedToInternet),
    ])
    func aFailedRefreshRefusesOnce(_ failure: URLError) async throws {
        let engine = engine(document: E.movedPins(promptRoots: []))
        let fetcher = TLSPinDocumentFetcher(engine: engine, send: { _ in throw failure }, clock: { E.date })
        engine.install(refresh: { await fetcher.refetch() }, report: nil)
        let trust = try #require(F.trust(E.wwwChain, host: E.host, at: E.date))
        let challenge = URLAuthenticationChallenge(
            protectionSpace: ServerTrustSpace(host: E.host, trust: trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: NoChallengeSender()
        )
        let (calls, record) = AsyncStream<URLSession.AuthChallengeDisposition>.makeStream()
        TLSPinningDelegate(engine: engine).urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
            record.yield(disposition)
        }
        var dispositions = calls.makeAsyncIterator()
        let first = await dispositions.next()
        try await Task.sleep(for: .milliseconds(200))
        record.finish()
        let second = await dispositions.next()
        #expect(first == .cancelAuthenticationChallenge)
        #expect(second == nil)
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

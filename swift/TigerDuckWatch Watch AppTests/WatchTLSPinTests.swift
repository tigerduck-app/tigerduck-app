import CryptoKit
import Foundation
import Security
import Testing
@testable import TigerDuckWatch_Watch_App

/// The Watch's side of the pin sync: it verifies what the phone forwards and shows no prompt.
@MainActor
struct WatchTLSPinTests {
    nonisolated static let key = Curve25519.Signing.PrivateKey()
    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
    nonisolated static let unknownSPKI = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    nonisolated static let handMadeRoot = Data(base64Encoded: "MIIBtDCCAVqgAwIBAgIUVQTsZtsVUdY9WwIZtcn6sk5Y6BcwCgYIKoZIzj0EAwIwODEYMBYGA1UECgwPVGlnZXJEdWNrIFRlc3RzMRwwGgYDVQQDDBNUaWdlckR1Y2sgVGVzdCBSb290MB4XDTI2MTAyNDIxMDAxN1oXDTQ2MTAxOTIxMDAxN1owODEYMBYGA1UECgwPVGlnZXJEdWNrIFRlc3RzMRwwGgYDVQQDDBNUaWdlckR1Y2sgVGVzdCBSb290MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9ytNHF7+/irw55OpKPLFWZydTWmnZJ7aT0UIO0oZwM4TaOVUjg2Sc9ltJiXPpc/1K/t5hq56hrVBGcPnOp6XG6NCMEAwHQYDVR0OBBYEFEk8kYCIyTNdTGiyzdKFFUEj0+N2MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gAMEUCIDe94HQ4N318puD9f0TqrQ2iYgy3VYWNt9dLVB36jg6GAiEAky9gGQmaSwf8zKppS2tlirhfoGEBwspwlRu9Gpz58fE=")!

    static func engine(buildNumber: String = "100") -> TLSPinEngine {
        let name = "WatchTLSPinTests.\(UUID().uuidString)"
        return TLSPinEngine(
            builtIn: [TLSPinSet(id: "library", domains: [.init(name: "api.lib.ntust.edu.tw", includeSubdomains: true)],
                                pins: [unknownSPKI], expiresAt: .distantFuture)],
            keys: ["td-pins-test": key.publicKey], defaults: UserDefaults(suiteName: name)!,
            buildNumber: buildNumber, clock: { now }
        )
    }

    static func envelope(signedBy signer: Curve25519.Signing.PrivateKey = key) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "format": 1, "serial": 7, "issued_at": "2026-10-25T00:00:00Z", "expires_at": "2026-11-24T00:00:00Z",
            "pin_sets": [], "prompt_roots": [],
        ] as [String: Any])
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try JSONSerialization.data(withJSONObject: [
            "format": 1, "key_id": "td-pins-test",
            "payload": base64URL(payload), "signature": base64URL(try signer.signature(for: payload)),
        ])
    }

    static func message(envelope: Data, buildNumber: String = "100", sentAtMs: Int64 = 1) throws -> [String: Any] {
        let acceptance = TLSPinAcceptance(setID: "library", spkis: ["accepted"], buildNumber: buildNumber, acceptedAt: now)
        let payload = WatchTLSPinPayload(sentAtMs: sentAtMs, envelope: envelope, acceptances: [acceptance])
        return [
            WatchWireFormat.LibraryCredentialKey.kind: WatchWireFormat.UserInfoKind.tlsPins,
            WatchWireFormat.LibraryCredentialKey.payload: try payload.encodedJSON(),
        ]
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "WatchTLSPinTests.\(UUID().uuidString)")!
    }

    @Test("A forwarded envelope the Watch verifies is applied, with its build's acceptances")
    func aVerifiedEnvelopeIsApplied() throws {
        let engine = Self.engine()
        let envelope = try Self.envelope()
        ScheduleStore.route(try Self.message(envelope: envelope), source: "test", pinEngine: engine, pinDefaults: defaults())
        #expect(engine.storedEnvelope == envelope)
        #expect(engine.acceptances.map(\.spkis) == [["accepted"]])
    }

    @Test("An envelope signed by another key is refused")
    func anUnverifiedEnvelopeIsRefused() throws {
        let engine = Self.engine()
        let envelope = try Self.envelope(signedBy: Curve25519.Signing.PrivateKey())
        ScheduleStore.route(try Self.message(envelope: envelope), source: "test", pinEngine: engine, pinDefaults: defaults())
        #expect(engine.storedEnvelope == nil)
    }

    @Test("Acceptances made under another build are not applied")
    func anotherBuildsAcceptancesAreDropped() throws {
        let engine = Self.engine(buildNumber: "101")
        ScheduleStore.route(try Self.message(envelope: try Self.envelope()), source: "test", pinEngine: engine, pinDefaults: defaults())
        #expect(engine.acceptances.isEmpty)
    }

    @Test("A message of an unknown kind leaves the pins alone")
    func anUnknownKindIsIgnored() throws {
        let engine = Self.engine()
        var message = try Self.message(envelope: try Self.envelope())
        message[WatchWireFormat.LibraryCredentialKey.kind] = "somethingElse"
        ScheduleStore.route(message, source: "test", pinEngine: engine, pinDefaults: defaults())
        #expect(engine.storedEnvelope == nil)
    }

    @Test("A refused library chain asks the user to open the phone; other failures keep their error")
    func aMismatchShowsTheOpenPhoneHint() async throws {
        let engine = Self.engine()
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.handMadeRoot as CFData))
        let other = URLError(.cancelled)
        #expect((WatchLibraryService.pinMismatchOr(other, host: "api.lib.ntust.edu.tw", engine: engine) as? URLError) == other)

        #expect(await engine.resolveRefusal(host: "api.lib.ntust.edu.tw", chain: [certificate]) == false)
        let offline = URLError(.notConnectedToInternet)
        #expect((WatchLibraryService.pinMismatchOr(offline, host: "api.lib.ntust.edu.tw", engine: engine) as? URLError) == offline)
        let error = WatchLibraryService.pinMismatchOr(other, host: "api.lib.ntust.edu.tw", engine: engine)
        #expect(error.localizedDescription == String(localized: "watch_open_phone_to_sync"))
        guard case WatchLibraryServiceError.pinMismatch = error else {
            Issue.record("expected pinMismatch, got \(error)")
            return
        }
    }
}

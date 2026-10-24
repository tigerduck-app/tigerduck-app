import CryptoKit
import Foundation
import Testing
@testable import TigerDuck

struct TLSPinDocumentTests {
    typealias F = TLSPinFixtures

    static let host = "moodle2.ntust.edu.tw"

    private func pins(_ engine: TLSPinEngine, host: String = Self.host) -> TLSPinSet? {
        guard case .pinned(let set) = engine.policy(forHost: host) else { return nil }
        return set
    }

    @Test("A valid document replaces the built-in pins of the sets it lists")
    func aValidDocumentApplies() throws {
        let engine = F.engine()
        let envelope = F.envelope(F.payload(sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])]))
        #expect(engine.acceptDocument(envelope) == .applied)
        #expect(try #require(pins(engine)).pins == [F.unknownSPKI])
        #expect(engine.storedEnvelope == envelope)
    }

    @Test("The app accepts the server key and its offline standby")
    func theBuiltInKeysParse() {
        #expect(TLSPinDocument.keys(fromBase64: TLSPinTable.signingKeys).keys.sorted() == ["td-pins-2026a", "td-pins-2026b"])
    }

    @Test("A bad signature, an unknown key or an unknown format is no document")
    func rejectedEnvelopes() {
        let payload = F.payload(sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])])
        let rejected = [
            F.envelope(payload, signedBy: Curve25519.Signing.PrivateKey()),
            F.envelope(payload, keyID: "td-pins-unknown"),
            F.envelope(payload, format: 2),
            F.envelope(F.payload(sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])], format: 2)),
            Data("not json".utf8),
        ]
        for envelope in rejected {
            let engine = F.engine()
            #expect(engine.acceptDocument(envelope) == .rejected)
            #expect(pins(engine)?.pins == TLSPinTable.builtIn[0].pins)
        }
    }

    @Test("The signature covers the payload bytes, so a changed payload fails")
    func aTamperedPayloadFails() throws {
        let payload = F.payload(serial: 100)
        let signed = try JSONSerialization.jsonObject(with: F.envelope(payload)) as! [String: Any]
        var tampered = signed
        tampered["payload"] = F.base64URL(F.payload(serial: 101))
        let envelope = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: TLSPinDocument.Failure.badSignature) {
            try TLSPinDocument.verify(envelope: envelope, keys: F.keys)
        }
    }

    @Test("A lower serial, or an equal one with other bytes, never replaces the held document")
    func serialsNeverGoBack() {
        let engine = F.engine()
        #expect(engine.acceptDocument(F.envelope(F.payload(serial: 200))) == .applied)
        #expect(engine.acceptDocument(F.envelope(F.payload(serial: 199))) == .rejected)
        #expect(engine.acceptDocument(F.envelope(F.payload(serial: 200, promptRoots: [F.unknownSPKI]))) == .rejected)
        #expect(engine.acceptDocument(F.envelope(F.payload(serial: 200))) == .unchanged)
        #expect(engine.acceptDocument(F.envelope(F.payload(serial: 201))) == .applied)
    }

    @Test("An expired document is refused, and a held one stops applying once it expires")
    func expiredDocuments() throws {
        let expired = F.envelope(F.payload(expiresAt: F.now.addingTimeInterval(-1)))
        #expect(F.engine().acceptDocument(expired) == .rejected)

        let defaults = F.defaults()
        let envelope = F.envelope(F.payload(
            expiresAt: F.now.addingTimeInterval(F.day),
            sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])]
        ))
        #expect(F.engine(defaults: defaults).acceptDocument(envelope) == .applied)
        let later = F.engine(defaults: defaults, now: F.now.addingTimeInterval(2 * F.day))
        #expect(try #require(pins(later)).pins == TLSPinTable.builtIn[0].pins)
    }

    @Test("A set the document leaves out keeps its built-in pins")
    func aMissingSetKeepsItsBuiltInPins() throws {
        let engine = F.engine()
        engine.acceptDocument(F.envelope(F.payload(sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])])))
        let library = try #require(pins(engine, host: "api.lib.ntust.edu.tw"))
        #expect(library.pins == TLSPinTable.builtIn[1].pins)
    }

    @Test("A document can move a set's expiry later, never earlier")
    func setExpiryOnlyMovesLater() throws {
        let builtInExpiry = TLSPinTable.builtIn[0].expiresAt
        let earlier = F.engine()
        earlier.acceptDocument(F.envelope(F.payload(sets: [
            F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI], expiresAt: F.now.addingTimeInterval(F.day)),
        ])))
        #expect(try #require(pins(earlier)).expiresAt == builtInExpiry)

        let laterExpiry = builtInExpiry.addingTimeInterval(100 * F.day)
        let later = F.engine()
        later.acceptDocument(F.envelope(F.payload(expiresAt: laterExpiry, sets: [
            F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI], expiresAt: laterExpiry),
        ])))
        #expect(try #require(pins(later)).expiresAt == laterExpiry)
        guard case .pinned = later.policy(forHost: Self.host, now: builtInExpiry.addingTimeInterval(F.day)) else {
            Issue.record("the extended set stopped enforcing at the built-in expiry")
            return
        }
    }

    @Test("A document no newer than the built-in table's baseline does not replace it")
    func theBaselineSerialGates() throws {
        let engine = F.engine(baselineSerial: 100)
        engine.acceptDocument(F.envelope(F.payload(serial: 100, sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])])))
        #expect(try #require(pins(engine)).pins == TLSPinTable.builtIn[0].pins)
    }

    @Test("The stored envelope is verified again on load")
    func storedDocumentsAreVerifiedOnLoad() throws {
        let defaults = F.defaults()
        let envelope = F.envelope(F.payload(sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])]))
        F.engine(defaults: defaults).acceptDocument(envelope)
        #expect(try #require(pins(F.engine(defaults: defaults))).pins == [F.unknownSPKI])

        let unknownKey = TLSPinEngine(keys: [:], defaults: defaults, buildNumber: "100", clock: { F.now })
        #expect(try #require(pins(unknownKey)).pins == TLSPinTable.builtIn[0].pins)
        #expect(defaults.data(forKey: "tlsPinDocumentEnvelope") == nil)
    }

    @Test("The most specific domain wins, and a trailing dot still matches")
    func matching() {
        let engine = F.engine()
        guard case .pinned(let library) = engine.policy(forHost: "API.lib.ntust.edu.tw.") else {
            Issue.record("api.lib.ntust.edu.tw is not pinned")
            return
        }
        #expect(library.id == "library")
        guard case .pinned(let ntust) = engine.policy(forHost: "lib.ntust.edu.tw") else {
            Issue.record("lib.ntust.edu.tw is not pinned")
            return
        }
        #expect(ntust.id == "ntust")
        #expect(engine.policy(forHost: "example.com") == .notPinned)
        #expect(engine.policy(forHost: "notntust.edu.tw") == .notPinned)
    }
}

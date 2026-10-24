#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct TLSPinWatchSyncTests {
    typealias F = TLSPinFixtures

    static let acceptance = TLSPinMismatchQueueTests.mismatch()

    private func phonePayload(envelope: Data, sentAt: Date = F.now) throws -> String {
        let phone = F.engine()
        phone.acceptDocument(envelope)
        phone.accept(Self.acceptance)
        let broadcaster = TLSPinWatchBroadcaster(
            session: WatchSyncCoordinatorTests.StubSession(), engine: phone, clock: { sentAt }
        )
        let userInfo = try #require(broadcaster.userInfo())
        #expect(userInfo[WatchWireFormat.LibraryCredentialKey.kind] as? String == WatchWireFormat.UserInfoKind.tlsPins)
        return try #require(userInfo[WatchWireFormat.LibraryCredentialKey.payload] as? String)
    }

    @Test("The watch verifies the forwarded envelope and takes acceptances made under its build")
    func theWatchAppliesAVerifiedEnvelope() throws {
        let envelope = F.envelope(F.payload(serial: 120))
        let watch = F.engine(buildNumber: "100")
        #expect(WatchTLSPinPayload.apply(json: try phonePayload(envelope: envelope), to: watch, defaults: F.defaults()))
        #expect(watch.storedEnvelope == envelope)
        #expect(watch.acceptances.map(\.spkis) == [Self.acceptance.acceptedSPKIs])
    }

    @Test("The watch drops acceptances from another build")
    func anotherBuildsAcceptancesAreDropped() throws {
        let watch = F.engine(buildNumber: "99")
        WatchTLSPinPayload.apply(json: try phonePayload(envelope: F.envelope(F.payload())), to: watch, defaults: F.defaults())
        #expect(watch.acceptances.isEmpty)
    }

    @Test("The watch refuses an envelope its keys do not verify")
    func anUnverifiedEnvelopeIsRefused() throws {
        let watch = TLSPinEngine(keys: [:], defaults: F.defaults(), buildNumber: "100", clock: { F.now })
        WatchTLSPinPayload.apply(json: try phonePayload(envelope: F.envelope(F.payload())), to: watch, defaults: F.defaults())
        #expect(watch.storedEnvelope == nil)
    }

    @Test("A payload no newer than the last one applied is dropped")
    func olderPayloadsAreDropped() throws {
        let defaults = F.defaults()
        let watch = F.engine()
        let applied = F.envelope(F.payload(serial: 130))
        let newer = try phonePayload(envelope: applied, sentAt: F.now.addingTimeInterval(60))
        let older = try phonePayload(envelope: F.envelope(F.payload(serial: 140)), sentAt: F.now)
        #expect(WatchTLSPinPayload.apply(json: newer, to: watch, defaults: defaults))
        #expect(!WatchTLSPinPayload.apply(json: newer, to: watch, defaults: defaults))
        #expect(!WatchTLSPinPayload.apply(json: older, to: watch, defaults: defaults))
        #expect(watch.storedEnvelope == applied)
    }
}
#endif

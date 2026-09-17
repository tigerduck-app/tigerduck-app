#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailMoverTests {
    static let trash = MailFolderRole.trash.imapName

    @Test func movesAndExpungesWhenNothingElseIsFlagged() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 2)]])
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        let result = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        #expect(result == MailMoveResult(expunged: true, stillPending: OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])))
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "copy [1] \(Self.trash)", "setFlag deleted true [1]", "deletedUIDs INBOX", "expunge INBOX"])
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [2])
        #expect(await fake.folders[Self.trash]?.count == 1)
    }

    @Test func leavesOtherClientsDeletedMailAlone() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [
            FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 3, deleted: true),
        ]])
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        let result = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        #expect(result == MailMoveResult(expunged: false, stillPending: OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [1])))
        #expect(!(await fake.calls).contains("expunge INBOX"))
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1, 3])
    }

    @Test func expungesLaterOnceOnlyOurFlagsRemain() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [
            FakeMailClient.message(uid: 1, deleted: true), FakeMailClient.message(uid: 2),
        ]])
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [1])
        let result = try await MailMover.deletePermanently(uids: [2], in: "INBOX", client: fake, previouslyFlagged: previouslyFlagged)
        #expect(result.expunged)
        #expect(await fake.folders["INBOX"]?.isEmpty == true)
    }

    @Test func expungeRule() {
        #expect(MailMover.shouldExpunge(deleted: [1, 2], ours: [1, 2, 5]))
        #expect(!MailMover.shouldExpunge(deleted: [1, 9], ours: [1]))
        #expect(!MailMover.shouldExpunge(deleted: [], ours: [1]))
    }

    // MARK: UIDVALIDITY / folder guard

    @Test func refusesAndTouchesNothingWhenUIDValidityChanged() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.uidValidity["INBOX"] = 7 }
        // A stale owned set recorded under the old generation, carrying a UID (99) that could
        // otherwise belong to someone else's mail under the new one -- exactly what must never
        // reach `shouldExpunge` once the folder has moved on to a new UIDVALIDITY.
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [99])
        await #expect(throws: MailClientError.folderChanged) {
            _ = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX"])
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1])
        #expect(await fake.folders[Self.trash] == nil)
    }

    /// The app polls its own INBOX every 60 s on the same client the message screen moves and
    /// deletes through, and `MailMover`'s steps are separate commands with the connection lock
    /// released between them. A poll that lands mid-sequence must not be able to "refresh" the
    /// folder's UIDVALIDITY into the value the guard compares against, or the guard compares a
    /// value against itself and an EXPUNGE reaches mail the user never touched.
    @Test func aPollBetweenTheMoversStepsCannotDefeatTheUIDValidityGuard() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 2)]])
        await fake.update { $0.uidValidity["INBOX"] = 1 }
        await fake.hold("setFlag")
        let pinned = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        let mover = Task {
            try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake, previouslyFlagged: pinned)
        }
        // The mover's own freshness check has already passed against UIDVALIDITY 1, and its STORE
        // is parked on the wire.
        await fake.waitForArrival("setFlag")
        // The server recreates INBOX, and the page poll's own STATUS observes the new generation
        // before the parked STORE resumes.
        await fake.update { $0.uidValidity["INBOX"] = 2 }
        _ = try await fake.status(folder: "INBOX")
        await fake.release("setFlag")

        await #expect(throws: MailClientError.folderChanged) { _ = try await mover.value }
        let calls = await fake.calls
        #expect(!calls.contains("expunge INBOX"))
        // Nothing in the recreated folder was flagged, and nothing was destroyed.
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1, 2])
        #expect(await fake.folders["INBOX"]?.allSatisfy { !$0.summary.isDeleted } == true)
    }

    /// The same interleaving against `move`, whose COPY would otherwise file an arbitrary message
    /// from the recreated folder into the target.
    @Test func aPollBetweenTheMoversStepsCannotDefeatTheGuardOnCopyEither() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)], Self.trash: []])
        await fake.update { $0.uidValidity["INBOX"] = 1 }
        await fake.hold("copy")
        let pinned = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        let mover = Task {
            try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: pinned)
        }
        await fake.waitForArrival("copy")
        await fake.update { $0.uidValidity["INBOX"] = 2 }
        _ = try await fake.status(folder: "INBOX")
        await fake.release("copy")

        await #expect(throws: MailClientError.folderChanged) { _ = try await mover.value }
        #expect(await fake.folders[Self.trash]?.isEmpty == true)
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == false)
    }

    @Test func refusesWhenTheOwnedSetIsForADifferentFolder() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        let previouslyFlagged = OwnedDeleted(folder: Self.trash, uidValidity: 1, uids: [])
        await #expect(throws: MailClientError.folderChanged) {
            _ = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        }
        // The folder mismatch is caught locally -- not even a status round trip happens.
        #expect(await fake.calls.isEmpty)
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1])
    }

    // MARK: empty UID list

    @Test func moveWithNoUIDsNeverTouchesTheServer() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [7])
        let result = try await MailMover.move(uids: [], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        #expect(result == MailMoveResult(expunged: false, stillPending: previouslyFlagged))
        #expect(await fake.calls.isEmpty)
    }

    @Test func deletePermanentlyWithNoUIDsNeverTouchesTheServer() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [7])
        let result = try await MailMover.deletePermanently(uids: [], in: "INBOX", client: fake, previouslyFlagged: previouslyFlagged)
        #expect(result == MailMoveResult(expunged: false, stillPending: previouslyFlagged))
        #expect(await fake.calls.isEmpty)
    }

    // MARK: COPY / STORE ordering

    @Test func aFailedCopyNeverReachesStore() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.copyError = .unreachable }
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        await #expect(throws: MailClientError.unreachable) {
            _ = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "copy [1] \(Self.trash)"])
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == false)
    }

    @Test func aFailedStoreNeverReachesTheServerCheck() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.setFlagError = .unreachable }
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        await #expect(throws: MailClientError.unreachable) {
            _ = try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake, previouslyFlagged: previouslyFlagged)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "setFlag deleted true [1]"])
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == false)
    }

    // MARK: server-side deleted check / recovery after a throw

    @Test func recoversOwnershipWhenTheFlagLandedDespiteAThrow() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.deletedUIDsError = .serverBusy }
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        await #expect(throws: MailClientError.serverBusy) {
            _ = try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake, previouslyFlagged: previouslyFlagged)
        }
        // STORE reached the server before the deleted-UID check threw.
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == true)
        let recovered = await MailMover.recoverAfterFailure(
            after: MailClientError.serverBusy, uid: 1, previouslyFlagged: previouslyFlagged,
            client: fake, wasAlreadyDeleted: false
        )
        #expect(recovered == OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [1]))
        // Exactly one fresh read to recover, on top of the failed attempt -- no retry of anything.
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "setFlag deleted true [1]", "deletedUIDs INBOX", "flags INBOX 1...1"])
    }

    @Test func neverAttributesAMessageAnotherClientHadAlreadyDeleted() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1, deleted: true)]])
        let recovered = await MailMover.recoverAfterFailure(
            after: MailClientError.serverBusy, uid: 1,
            previouslyFlagged: OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: []),
            client: fake, wasAlreadyDeleted: true
        )
        #expect(recovered == nil)
    }

    /// The probe reads flags to decide whether a `\Deleted` UID becomes one TigerDuck may later
    /// EXPUNGE, so it is pinned like every other step: a folder recreated between the failed
    /// command and the probe must not have one of *its* messages attributed to this app.
    @Test func theOwnershipProbeRefusesOnceTheFolderHasBeenRecreated() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1, deleted: true)]])
        await fake.update { $0.uidValidity["INBOX"] = 2 }
        let recovered = await MailMover.recoverAfterFailure(
            after: MailClientError.serverBusy, uid: 1,
            previouslyFlagged: OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: []),
            client: fake, wasAlreadyDeleted: false
        )
        #expect(recovered == nil)
    }

    @Test func theOwnershipProbeIsSkippedAfterARejectionThatWouldOnlyRepeatItself() {
        #expect(!MailMover.shouldProbeAfterFailure(MailClientError.authenticationFailed))
        #expect(!MailMover.shouldProbeAfterFailure(MailClientError.certificateRejected))
        #expect(!MailMover.shouldProbeAfterFailure(MailClientError.folderChanged))
        #expect(MailMover.shouldProbeAfterFailure(MailClientError.serverBusy))
        #expect(MailMover.shouldProbeAfterFailure(MailClientError.unreachable))
    }

    @Test func recordAfterFailureRule() {
        #expect(MailMover.shouldRecordAfterFailure(serverConfirmsDeleted: true, wasAlreadyDeleted: false))
        #expect(!MailMover.shouldRecordAfterFailure(serverConfirmsDeleted: true, wasAlreadyDeleted: true))
        #expect(!MailMover.shouldRecordAfterFailure(serverConfirmsDeleted: false, wasAlreadyDeleted: false))
    }

    // The "user search contract (no client-side fallback)" test that used to sit here only
    // asserted that `FakeMailClient.search` throws the error the test had just assigned to
    // `fake.searchError`: no `MailMover`, `LiveMailClient` or view-model code was involved, and
    // it passed with all three deleted. The real contract — the list falling back to loaded mail
    // when the server refuses SEARCH — is covered by
    // `MailListViewModelTests.searchFallsBackToLoadedMailWhenTheServerRefuses`.
}
#endif

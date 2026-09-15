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
        let recovered = await MailMover.recoverAfterFailure(uid: 1, folder: "INBOX", client: fake, wasAlreadyDeleted: false)
        #expect(recovered)
        // Exactly one fresh read to recover, on top of the failed attempt -- no retry of anything.
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "setFlag deleted true [1]", "deletedUIDs INBOX", "flags INBOX 1...1"])
    }

    @Test func neverAttributesAMessageAnotherClientHadAlreadyDeleted() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1, deleted: true)]])
        let recovered = await MailMover.recoverAfterFailure(uid: 1, folder: "INBOX", client: fake, wasAlreadyDeleted: true)
        #expect(!recovered)
    }

    @Test func recordAfterFailureRule() {
        #expect(MailMover.shouldRecordAfterFailure(serverConfirmsDeleted: true, wasAlreadyDeleted: false))
        #expect(!MailMover.shouldRecordAfterFailure(serverConfirmsDeleted: true, wasAlreadyDeleted: true))
        #expect(!MailMover.shouldRecordAfterFailure(serverConfirmsDeleted: false, wasAlreadyDeleted: false))
    }

    // MARK: user search contract (no client-side fallback)

    @Test func aRejectedSearchSurfacesAsSearchUnsupported() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1, subject: "hello")]])
        await fake.update { $0.searchError = .searchUnsupported }
        await #expect(throws: MailClientError.searchUnsupported) {
            _ = try await fake.search(folder: "INBOX", query: "hello")
        }
    }
}
#endif

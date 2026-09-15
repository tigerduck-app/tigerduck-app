#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailMoverTests {
    static let trash = MailFolderRole.trash.imapName

    @Test func movesAndExpungesWhenNothingElseIsFlagged() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 2)]])
        let result = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake,
                                              previouslyFlagged: [], expectedUIDValidity: 1)
        #expect(result == MailMoveResult(expunged: true, stillPending: []))
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "copy [1] \(Self.trash)", "setFlag deleted true [1]", "deletedUIDs INBOX", "expunge INBOX"])
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [2])
        #expect(await fake.folders[Self.trash]?.count == 1)
    }

    @Test func leavesOtherClientsDeletedMailAlone() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [
            FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 3, deleted: true),
        ]])
        let result = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake,
                                              previouslyFlagged: [], expectedUIDValidity: 1)
        #expect(result == MailMoveResult(expunged: false, stillPending: [1]))
        #expect(!(await fake.calls).contains("expunge INBOX"))
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1, 3])
    }

    @Test func expungesLaterOnceOnlyOurFlagsRemain() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [
            FakeMailClient.message(uid: 1, deleted: true), FakeMailClient.message(uid: 2),
        ]])
        let result = try await MailMover.deletePermanently(uids: [2], in: "INBOX", client: fake,
                                                            previouslyFlagged: [1], expectedUIDValidity: 1)
        #expect(result.expunged)
        #expect(await fake.folders["INBOX"]?.isEmpty == true)
    }

    @Test func expungeRule() {
        #expect(MailMover.shouldExpunge(deleted: [1, 2], ours: [1, 2, 5]))
        #expect(!MailMover.shouldExpunge(deleted: [1, 9], ours: [1]))
        #expect(!MailMover.shouldExpunge(deleted: [], ours: [1]))
    }

    // MARK: UIDVALIDITY guard

    @Test func refusesAndTouchesNothingWhenUIDValidityChanged() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.uidValidity["INBOX"] = 7 }
        await #expect(throws: MailClientError.folderChanged) {
            _ = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake,
                                         previouslyFlagged: [], expectedUIDValidity: 1)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX"])
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1])
        #expect(await fake.folders[Self.trash] == nil)
    }

    // MARK: COPY / STORE ordering

    @Test func aFailedCopyNeverReachesStore() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.copyError = .unreachable }
        await #expect(throws: MailClientError.unreachable) {
            _ = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake,
                                         previouslyFlagged: [], expectedUIDValidity: 1)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "copy [1] \(Self.trash)"])
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == false)
    }

    @Test func aFailedStoreNeverReachesTheServerCheck() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.setFlagError = .unreachable }
        await #expect(throws: MailClientError.unreachable) {
            _ = try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake,
                                                       previouslyFlagged: [], expectedUIDValidity: 1)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX", "setFlag deleted true [1]"])
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == false)
    }

    // MARK: server-side deleted check

    @Test func recoversOwnershipWhenTheFlagLandedDespiteAThrow() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.deletedUIDsError = .serverBusy }
        await #expect(throws: MailClientError.serverBusy) {
            _ = try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake,
                                                       previouslyFlagged: [], expectedUIDValidity: 1)
        }
        #expect(!(await fake.calls).contains("expunge INBOX"))
        // STORE reached the server before the deleted-UID check threw.
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == true)
        let recovered = await MailMover.recoverAfterFailure(uid: 1, folder: "INBOX", client: fake, wasAlreadyDeleted: false)
        #expect(recovered)
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

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

    @Test func refusesAndTouchesNothingWhenUIDValidityChanged() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.uidValidity["INBOX"] = 7 }
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [99])
        await #expect(throws: MailClientError.folderChanged) {
            _ = try await MailMover.move(uids: [1], from: "INBOX", to: Self.trash, client: fake, previouslyFlagged: previouslyFlagged)
        }
        let calls = await fake.calls
        #expect(calls == ["status INBOX"])
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1])
        #expect(await fake.folders[Self.trash] == nil)
    }

    @Test func aPollBetweenTheMoversStepsCannotDefeatTheUIDValidityGuard() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 2)]])
        await fake.update { $0.uidValidity["INBOX"] = 1 }
        await fake.hold("setFlag")
        let pinned = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        let mover = Task {
            try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake, previouslyFlagged: pinned)
        }
        await fake.waitForArrival("setFlag")
        await fake.update { $0.uidValidity["INBOX"] = 2 }
        _ = try await fake.status(folder: "INBOX")
        await fake.release("setFlag")

        await #expect(throws: MailClientError.folderChanged) { _ = try await mover.value }
        let calls = await fake.calls
        #expect(!calls.contains("expunge INBOX"))
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1, 2])
        #expect(await fake.folders["INBOX"]?.allSatisfy { !$0.summary.isDeleted } == true)
    }

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
        #expect(await fake.calls.isEmpty)
        #expect(await fake.folders["INBOX"]?.map(\.summary.uid) == [1])
    }

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

    @Test func recoversOwnershipWhenTheFlagLandedDespiteAThrow() async throws {
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        await fake.update { $0.deletedUIDsError = .serverBusy }
        let previouslyFlagged = OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [])
        await #expect(throws: MailClientError.serverBusy) {
            _ = try await MailMover.deletePermanently(uids: [1], in: "INBOX", client: fake, previouslyFlagged: previouslyFlagged)
        }
        #expect(await fake.folders["INBOX"]?.first?.summary.isDeleted == true)
        let recovered = await MailMover.recoverAfterFailure(
            after: MailClientError.serverBusy, uid: 1, previouslyFlagged: previouslyFlagged,
            client: fake, wasAlreadyDeleted: false
        )
        #expect(recovered == OwnedDeleted(folder: "INBOX", uidValidity: 1, uids: [1]))
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

}
#endif

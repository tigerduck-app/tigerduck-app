#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailIndexerTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    struct Harness {
        let indexer: MailIndexer
        let fake: FakeMailClient
        let cache: MailCache
        let clock: Clock

        func search(_ query: String, in folder: String = "INBOX") -> [UInt32]? {
            cache.searchIndex.search(folder: folder, query: query)?.uids
        }

        func textBatches(_ folder: String = "INBOX") async -> [String] {
            await fake.calls.filter { $0.hasPrefix("searchTexts \(folder) ") }
        }
    }

    static func harness(inboxCount: UInt32 = 45) -> Harness {
        let inbox = (UInt32(1)...inboxCount).map {
            FakeMailClient.message(uid: $0, subject: "公告 \($0)", text: "內文 \($0) Body")
        }
        let fake = FakeMailClient(folders: ["INBOX": inbox, "Sent": [FakeMailClient.message(uid: 1, subject: "寄件")]])
        let cache = SchoolMailTestDoubles.temporaryCache()
        let clock = Clock()
        let session = MailPageSession(idleClose: .milliseconds(10), open: { fake }, signOutEvents: NotificationCenter())
        let indexer = MailIndexer(session: session, cache: cache, startDelay: {}, now: { clock.now })
        return Harness(indexer: indexer, fake: fake, cache: cache, clock: clock)
    }

    @Test func downloadsAFolderNewestFirstInBatches() async throws {
        let h = Self.harness()
        #expect(try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount))

        let batches = await h.textBatches()
        #expect(batches == [
            "searchTexts INBOX \(Array((UInt32(26)...45).reversed()))",
            "searchTexts INBOX \(Array((UInt32(6)...25).reversed()))",
            "searchTexts INBOX \(Array((UInt32(1)...5).reversed()))",
        ])
        #expect(h.search("內文 7 body") == [7])
        #expect(h.search("公告 4") == [45, 44, 43, 42, 41, 40, 4])
    }

    @Test func aLaterUpdateFetchesOnlyTheMailThatArrived() async throws {
        let h = Self.harness(inboxCount: 3)
        _ = try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount)
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4, subject: "新信", text: "補考")) }

        _ = try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount)

        #expect(await h.textBatches() == ["searchTexts INBOX [3, 2, 1]", "searchTexts INBOX [4]"])
        #expect(h.search("補考") == [4])
    }

    @Test func mailDeletedOnTheServerLeavesTheIndex() async throws {
        let h = Self.harness(inboxCount: 3)
        _ = try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount)
        await h.fake.update { fake in
            fake.folders["INBOX"]?.removeAll { $0.summary.uid == 1 }
            fake.folders["INBOX"]?[0].summary.isDeleted = true
        }

        _ = try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount)

        #expect(h.search("公告") == [3])
    }

    @Test func aRecreatedFolderIsDownloadedAgainUnderItsNewUIDValidity() async throws {
        let h = Self.harness(inboxCount: 3)
        _ = try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount)
        await h.fake.update { fake in
            fake.uidValidity["INBOX"] = 2
            fake.folders["INBOX"] = [FakeMailClient.message(uid: 1, subject: "重建")]
        }

        _ = try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount)

        #expect(h.search("公告") == [])
        #expect(h.search("重建") == [1])
        #expect(h.cache.searchIndex.search(folder: "INBOX", query: "重建")?.uidValidity == 2)
        #expect(await h.textBatches().last == "searchTexts INBOX [1]")
    }

    @Test func aFolderRecreatedDuringTheDownloadStopsIt() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.fake.hold("searchTexts")
        let update = Task { try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) }
        await h.fake.waitForArrival("searchTexts")
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        await h.fake.release("searchTexts")

        await #expect(throws: MailClientError.folderChanged) { try await update.value }
        #expect(h.search("公告") == [])
    }

    @Test func aSignOutDuringTheDownloadLeavesNothingBehind() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.fake.hold("searchTexts")
        let update = Task { try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) }
        await h.fake.waitForArrival("searchTexts")
        h.cache.clearAll()
        await h.fake.release("searchTexts")

        #expect(try await update.value == false)
        #expect(h.search("公告") == nil)
    }

    @Test func aPassThatGotThroughHoldsOffTheNextUntilMailArrivesOrTimePasses() async {
        let h = Self.harness(inboxCount: 3)
        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        #expect(h.search("寄件", in: "Sent") == [1])

        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        #expect(await h.fake.calls.filter { $0.hasPrefix("undeletedUIDs INBOX") }.count == 1)

        h.indexer.noteNewMail()
        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        #expect(await h.fake.calls.filter { $0.hasPrefix("undeletedUIDs INBOX") }.count == 2)

        h.clock.now += MailConstants.indexResyncInterval
        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        #expect(await h.fake.calls.filter { $0.hasPrefix("undeletedUIDs INBOX") }.count == 3)
    }

    @Test func aLostConnectionEndsThePassAndLeavesItDue() async {
        let h = Self.harness(inboxCount: 3)
        await h.fake.update { $0.searchTextsError = .unreachable }
        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        let calls = await h.fake.calls
        #expect(!calls.contains("undeletedUIDs Sent"))

        await h.fake.update { $0.searchTextsError = nil }
        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        #expect(h.search("公告") == [3, 2, 1])
    }

    @Test func aCancelledDownloadKeepsTheBatchInFlightAndSendsNoOther() async throws {
        let h = Self.harness()
        await h.fake.hold("searchTexts")
        let update = Task { try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) }
        await h.fake.waitForArrival("searchTexts")
        update.cancel()
        await h.fake.release("searchTexts")

        #expect(try await update.value == false)
        #expect(await h.textBatches().count == 1)
        #expect(h.search("公告 45") == [45])
    }
}
#endif

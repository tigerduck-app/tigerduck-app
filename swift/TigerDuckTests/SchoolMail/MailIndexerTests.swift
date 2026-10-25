#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailIndexerTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    final class Network {
        var isConstrained = false
    }

    @MainActor
    struct Harness {
        let indexer: MailIndexer
        let fake: FakeMailClient
        let cache: MailCache
        let clock: Clock
        let network: Network

        func search(_ query: String, in folder: String = "INBOX") -> [UInt32]? {
            cache.searchIndex.search(folder: folder, query: query)?.uids
        }

        func textBatches(_ folder: String = "INBOX") async -> [String] {
            await fake.calls.filter { $0.hasPrefix("searchTexts \(folder) ") }
        }

        func passes() async -> Int {
            await fake.calls.filter { $0 == "undeletedUIDs INBOX" }.count
        }

        func runPass() async {
            indexer.startIfDue(folders: ["INBOX"])
            await indexer.waitForPass()
        }
    }

    static func harness(inboxCount: UInt32 = 45) -> Harness {
        let inbox = (UInt32(1)...inboxCount).map {
            FakeMailClient.message(uid: $0, subject: "公告 \($0)", text: "內文 \($0) Body")
        }
        let fake = FakeMailClient(folders: ["INBOX": inbox, "Sent": [FakeMailClient.message(uid: 1, subject: "寄件")]])
        let cache = SchoolMailTestDoubles.temporaryCache()
        let clock = Clock()
        let network = Network()
        let session = MailPageSession(idleClose: .milliseconds(10), open: { fake }, signOutEvents: NotificationCenter())
        let indexer = MailIndexer(session: session, cache: cache, startDelay: {}, now: { clock.now },
                                  isConstrained: { network.isConstrained })
        return Harness(indexer: indexer, fake: fake, cache: cache, clock: clock, network: network)
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
        h.clock.now += MailConstants.indexRetryDelay
        h.indexer.startIfDue(folders: ["INBOX", "Sent"])
        await h.indexer.waitForPass()
        #expect(h.search("公告") == [3, 2, 1])
    }

    @Test func aFailedPassWaitsLongerBeforeEachRetry() async {
        let h = Self.harness(inboxCount: 3)
        await h.fake.update { $0.searchTextsError = .serverBusy }
        await h.runPass()
        await h.runPass()
        #expect(await h.passes() == 1)

        h.clock.now += MailConstants.indexRetryDelay
        await h.runPass()
        #expect(await h.passes() == 2)

        h.clock.now += MailConstants.indexRetryDelay
        await h.runPass()
        #expect(await h.passes() == 2)
        h.clock.now += MailConstants.indexRetryDelay
        await h.runPass()
        #expect(await h.passes() == 3)

        await h.fake.update { $0.searchTextsError = nil }
        h.clock.now += 4 * MailConstants.indexRetryDelay
        await h.runPass()
        #expect(h.search("公告") == [3, 2, 1])

        await h.fake.update { fake in
            fake.folders["INBOX"]?.append(FakeMailClient.message(uid: 4, subject: "公告 4"))
            fake.searchTextsError = .serverBusy
        }
        h.indexer.noteNewMail()
        await h.runPass()
        h.clock.now += MailConstants.indexRetryDelay
        await h.runPass()
        #expect(await h.passes() == 6)
    }

    @Test func aMailWhoseTextNeverArrivesIsSkippedAfterFailingAloneTwice() async throws {
        let h = Self.harness()
        await h.fake.update { $0.searchTextsFailingUIDs = [30] }

        #expect(try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) == false)
        #expect(h.search("公告 25") == [25])
        #expect(h.search("公告 31") == [])
        #expect(try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) == false)
        #expect(h.search("公告 31") == [31])
        #expect(try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) == false)
        #expect(try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) == true)

        let tries = await h.textBatches().filter { $0.contains(" 30,") || $0.hasSuffix("[30]") }
        #expect(tries == [
            "searchTexts INBOX \(Array((UInt32(26)...45).reversed()))",
            "searchTexts INBOX [30]",
            "searchTexts INBOX [30]",
        ])
        #expect(h.search("公告 30") == [])
    }

    @Test func aBatchThatFailsAfterAStopCountsAgainstNoMail() async throws {
        let h = Self.harness()
        await h.fake.update { $0.searchTextsFailingUIDs = [30] }
        await h.fake.hold("searchTexts")
        let update = Task { try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount) }
        await h.fake.waitForArrival("searchTexts")
        update.cancel()
        await h.fake.release("searchTexts")
        #expect(try await update.value == false)

        await h.fake.update { $0.searchTextsFailingUIDs = [] }
        #expect(try await h.indexer.update(folder: "INBOX", wipeCount: h.cache.wipeCount))
        #expect(await h.textBatches().count == 4)
    }

    @Test func aPassStartedRightAfterAStopWaitsForTheStoppedOne() async {
        let h = Self.harness()
        await h.fake.hold("searchTexts")
        h.indexer.startIfDue(folders: ["INBOX"])
        await h.fake.waitForArrival("searchTexts")
        h.indexer.stop()
        h.indexer.startIfDue(folders: ["INBOX"])
        await h.fake.release("searchTexts")
        await h.indexer.waitForPass()

        #expect(await h.textBatches() == [
            "searchTexts INBOX \(Array((UInt32(26)...45).reversed()))",
            "searchTexts INBOX \(Array((UInt32(6)...25).reversed()))",
            "searchTexts INBOX \(Array((UInt32(1)...5).reversed()))",
        ])
    }

    @Test func lowDataModeKeepsAPassFromStarting() async {
        let h = Self.harness(inboxCount: 3)
        h.network.isConstrained = true
        await h.runPass()
        #expect(await h.passes() == 0)

        h.network.isConstrained = false
        await h.runPass()
        #expect(h.search("公告") == [3, 2, 1])
    }

    @Test func lowDataModeStopsAPassAfterItsBatchAndOffItResumesAtOnce() async {
        let h = Self.harness()
        await h.fake.hold("searchTexts")
        h.indexer.startIfDue(folders: ["INBOX"])
        await h.fake.waitForArrival("searchTexts")
        h.network.isConstrained = true
        await h.fake.release("searchTexts")
        await h.indexer.waitForPass()
        #expect(await h.textBatches().count == 1)
        #expect(h.search("公告 45") == [45])

        h.network.isConstrained = false
        await h.runPass()
        #expect(await h.textBatches().count == 3)
        #expect(h.search("公告 1") == [19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 1])
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

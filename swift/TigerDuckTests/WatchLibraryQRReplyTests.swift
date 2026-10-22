#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WatchLibraryQRReplyTests {
    @Test func aCodeFetchedAcrossASignOutReachesNeitherTheCacheNorTheWatch() async {
        let cache = LibraryQRCache()
        var generation = 1

        let reply = await WatchSyncCoordinator.libraryQRReply(cache: cache, generation: { generation }) {
            generation += 1
            return "departing-code"
        }

        #expect(reply[WatchWireFormat.LibraryQRKey.payload] == nil)
        #expect(reply[WatchWireFormat.LibraryQRKey.error] != nil)
        #expect(cache.reusable() == nil)
    }

    @Test func aCodeFetchedForTheSameAccountIsCachedAndSent() async {
        let cache = LibraryQRCache()

        let reply = await WatchSyncCoordinator.libraryQRReply(cache: cache, generation: { 1 }) { "code" }

        #expect(reply[WatchWireFormat.LibraryQRKey.payload] as? String == "code")
        #expect(cache.reusable() == "code")
    }
}
#endif

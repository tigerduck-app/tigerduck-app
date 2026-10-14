#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// The phone fetches a library code for the Watch with its own token. A sign-out while that
/// request is out leaves the code with the departing account
/// (https://github.com/tigerduck-app/tigerduck-app/issues/436).
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

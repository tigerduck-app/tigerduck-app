#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WatchLibraryQRReplyTests {
    @Test func aCodeFetchedAcrossASignOutReachesNeitherTheCacheNorTheWatch() async {
        let cache = LibraryQRCache()
        let account = AccountSession()

        let reply = await WatchSyncCoordinator.libraryQRReply(cache: cache, account: account) {
            account.moveOn()
            return "departing-code"
        }

        #expect(reply[WatchWireFormat.LibraryQRKey.payload] == nil)
        #expect(reply[WatchWireFormat.LibraryQRKey.error] != nil)
        #expect(cache.reusable() == nil)
    }

    @Test func aCodeFetchedForTheSameAccountIsCachedAndSent() async {
        let cache = LibraryQRCache()

        let reply = await WatchSyncCoordinator.libraryQRReply(cache: cache, account: AccountSession()) { "code" }

        #expect(reply[WatchWireFormat.LibraryQRKey.payload] as? String == "code")
        #expect(cache.reusable() == "code")
    }
}
#endif

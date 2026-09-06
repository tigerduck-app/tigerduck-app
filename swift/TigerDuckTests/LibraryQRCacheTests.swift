import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LibraryQRCacheTests {
    @Test("A code is reused while it has at least 15 s left")
    func reusesWhileFresh() {
        let cache = LibraryQRCache()
        let issued = Date()
        cache.store("abc", now: issued)
        #expect(cache.remaining(now: issued) == 30)
        #expect(cache.reusable(now: issued.addingTimeInterval(15)) == "abc")
        #expect(cache.reusable(now: issued.addingTimeInterval(16)) == nil)
        #expect(cache.remaining(now: issued.addingTimeInterval(45)) == 0)
    }

    @Test("A code handed over by the other device keeps its countdown")
    func honoursRemainingFromCounterpart() {
        let cache = LibraryQRCache()
        let now = Date()
        cache.store("abc", remaining: 20, now: now)
        #expect(cache.remaining(now: now) == 20)
        #expect(cache.reusable(now: now.addingTimeInterval(5)) == "abc")
        #expect(cache.reusable(now: now.addingTimeInterval(6)) == nil)
    }

    @Test("Clearing drops the code")
    func clearDropsEverything() {
        let cache = LibraryQRCache()
        cache.store("abc")
        cache.clear()
        #expect(cache.reusable() == nil)
        #expect(cache.remaining() == 0)
    }
}

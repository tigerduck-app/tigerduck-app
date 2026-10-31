#if os(iOS)
import Testing
@testable import TigerDuck

@MainActor
struct BrowserDataTests {
    @MainActor
    final class Disk {
        var state: BrowserDataState
        var removes = 0
        var clears = 0
        var removalSucceeds = true
        var holdsRemoval = false
        var holdsClear = false
        var heldRemoval: CheckedContinuation<Bool, Never>?
        var heldClear: CheckedContinuation<Void, Never>?

        init(_ state: BrowserDataState) { self.state = state }

        func data() -> BrowserData {
            BrowserData(
                loadState: { self.state },
                saveState: { self.state = $0 },
                remove: {
                    self.removes += 1
                    guard self.holdsRemoval else { return self.removalSucceeds }
                    return await withCheckedContinuation { self.heldRemoval = $0 }
                },
                clear: {
                    self.clears += 1
                    if self.holdsClear { await withCheckedContinuation { self.heldClear = $0 } }
                }
            )
        }
    }

    @Test func aResetWithNothingStoredRemovesNothing() {
        let disk = Disk(.empty)
        let data = disk.data()
        #expect(data.reset() == nil)
        #expect(data.epoch == 1)
        #expect(disk.removes == 0 && disk.state == .empty)
    }

    @Test func aBrowserMarksTheStoreUsedWithoutClearingIt() async {
        let disk = Disk(.empty)
        await disk.data().prepare()
        #expect(disk.state == .used && disk.clears == 0)
    }

    @Test func aResetRemovesTheStore() async {
        let disk = Disk(.used)
        let data = disk.data()
        await data.reset()?.value
        #expect(disk.removes == 1 && disk.clears == 0)
        #expect(disk.state == .empty)
    }

    @Test func aStoreThatCannotBeRemovedIsClearedNowAndAgainBeforeTheNextBrowser() async {
        let disk = Disk(.used)
        disk.removalSucceeds = false
        let data = disk.data()
        await data.reset()?.value
        #expect(disk.clears == 1 && disk.state == .stale)

        await data.prepare()
        #expect(disk.clears == 2 && disk.state == .used)
    }

    @Test func aStaleStoreFromALastLaunchIsClearedFirst() async {
        let disk = Disk(.stale)
        await disk.data().prepare()
        #expect(disk.clears == 1 && disk.state == .used)
    }

    @Test func aRemovalEndingAfterTheNextBrowserOpenedLeavesItsStoreAlone() async {
        let disk = Disk(.used)
        disk.holdsRemoval = true
        let data = disk.data()
        let removal = data.reset()
        while disk.heldRemoval == nil { await Task.yield() }

        await data.prepare()
        disk.heldRemoval?.resume(returning: true)
        await removal?.value
        #expect(disk.state == .used && disk.clears == 1)
    }

    @Test func aBrowserPreparingAcrossAResetDoesNotClaimTheStore() async {
        let disk = Disk(.stale)
        disk.holdsClear = true
        let data = disk.data()
        let preparing = Task { await data.prepare() }
        while disk.heldClear == nil { await Task.yield() }

        let removal = data.reset()
        disk.heldClear?.resume()
        await preparing.value
        await removal?.value
        #expect(disk.state == .empty)
    }
}
#endif

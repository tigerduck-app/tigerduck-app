#if os(iOS)
import Defaults
import SwiftUI
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct FlipToLibraryGateTests {
    @Test("signed out of the library, the Settings switch reads off whatever it holds")
    func switchReadsOffWhenSignedOut() {
        #expect(!LibrarySettingsView.flipSwitch(.constant(true), signedIn: false).wrappedValue)
        #expect(LibrarySettingsView.flipSwitch(.constant(true), signedIn: true).wrappedValue)
        #expect(!LibrarySettingsView.flipSwitch(.constant(false), signedIn: true).wrappedValue)
    }

    @Test("the flip listens only with the switch on, a library account signed in and the app in front")
    func flipNeedsALibraryAccount() {
        #expect(FlipToLibraryGate.isArmed(enabled: true, signedInToLibrary: true, inBackground: false))
        #expect(!FlipToLibraryGate.isArmed(enabled: true, signedInToLibrary: false, inBackground: false))
        #expect(!FlipToLibraryGate.isArmed(enabled: false, signedInToLibrary: true, inBackground: false))
        #expect(!FlipToLibraryGate.isArmed(enabled: true, signedInToLibrary: true, inBackground: true))
    }

    @Test("the gesture is offered once, to a library account with the switch off")
    func theGestureIsOfferedOnceAfterALibrarySignIn() {
        #expect(!Defaults.Key<Bool>.flipToLibraryEnabled.defaultValue)
        #expect(FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: false, asked: false, onLibraryPage: false))
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: false, enabled: false, asked: false, onLibraryPage: false))
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: true, asked: false, onLibraryPage: false))
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: false, asked: true, onLibraryPage: false))
    }

    @Test("the gesture is not offered over the Library page")
    func theOfferWaitsUntilTheLibraryPageIsLeft() {
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: false, asked: false, onLibraryPage: true))
    }

    @Test("each Library page counts once, until it goes")
    func eachLibraryPageCountsOnce() {
        let presence = LibraryPagePresence()
        let first = UUID(), second = UUID()
        presence.appear(first)
        presence.appear(second)
        presence.disappear(first)
        #expect(presence.isShown)
        presence.disappear(second)
        #expect(!presence.isShown)
        presence.appear(first)
        presence.appear(first)
        presence.disappear(first)
        #expect(!presence.isShown)
        presence.disappear(first)
        presence.appear(second)
        #expect(presence.isShown)
    }

    @Test("the offer waits behind a sheet already up and behind What's New or the update prompt")
    func theOfferWaitsForOtherSheets() {
        #expect(!FlipToLibraryGate.offerWaits(sheetPresented: false, notifySheetPending: false))
        #expect(FlipToLibraryGate.offerWaits(sheetPresented: true, notifySheetPending: false))
        #expect(FlipToLibraryGate.offerWaits(sheetPresented: false, notifySheetPending: true))
    }

    @Test("the flip opens the library weekdays from 08:10 to before 23:30, Taipei time")
    func weekdayHours() {
        // 2026-11-02 is a Monday.
        #expect(FlipToLibraryGate.opensLibrary(at: taipei(day: 2, 8, 10)))
        #expect(!FlipToLibraryGate.opensLibrary(at: taipei(day: 2, 8, 9, 59)))
        #expect(!FlipToLibraryGate.opensLibrary(at: taipei(day: 2, 23, 30)))
        #expect(FlipToLibraryGate.opensLibrary(at: taipei(day: 2, 23, 29, 59)))
    }

    @Test("the flip opens the library weekends from 08:30 to before 21:30, Taipei time", arguments: [7, 8])
    func weekendHours(day: Int) {
        // 2026-11-07 is a Saturday, 2026-11-08 a Sunday.
        #expect(FlipToLibraryGate.opensLibrary(at: taipei(day: day, 8, 30)))
        #expect(!FlipToLibraryGate.opensLibrary(at: taipei(day: day, 8, 29, 59)))
        #expect(!FlipToLibraryGate.opensLibrary(at: taipei(day: day, 21, 30)))
        #expect(FlipToLibraryGate.opensLibrary(at: taipei(day: day, 21, 29, 59)))
    }

    @Test("the hours are Taipei's whatever the device's time zone")
    func hoursFollowTaipeiTime() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        func atUTC(day: Int, _ hour: Int) throws -> Date {
            try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
        }
        // Monday 01:00 UTC is Monday 09:00 in Taipei.
        #expect(FlipToLibraryGate.opensLibrary(at: try atUTC(day: 2, 1)))
        // Monday 16:00 UTC is Tuesday 00:00 in Taipei.
        #expect(!FlipToLibraryGate.opensLibrary(at: try atUTC(day: 2, 16)))
        // Saturday 14:00 UTC is Saturday 22:00 in Taipei, past the weekend hours.
        #expect(!FlipToLibraryGate.opensLibrary(at: try atUTC(day: 7, 14)))
    }

    private func taipei(day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let parts = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second)
        return TaipeiTime.calendar.date(from: parts) ?? .distantPast
    }
}
#endif

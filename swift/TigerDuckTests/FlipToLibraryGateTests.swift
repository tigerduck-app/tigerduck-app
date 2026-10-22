#if os(iOS)
import Defaults
import SwiftUI
import Testing
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
}
#endif

#if os(iOS)
import Defaults
import SwiftUI
import Testing
@testable import TigerDuck

/// Flip-to-library needs a signed-in library account, since the flip opens its QR code.
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

    /// The switch is off by default, and a library sign-in asks once whether to turn it on
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/434).
    @Test("the gesture is offered once, to a library account with the switch off")
    func theGestureIsOfferedOnceAfterALibrarySignIn() {
        #expect(!Defaults.Key<Bool>.flipToLibraryEnabled.defaultValue)
        #expect(FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: false, asked: false, onLibraryPage: false))
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: false, enabled: false, asked: false, onLibraryPage: false))
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: true, asked: false, onLibraryPage: false))
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: false, asked: true, onLibraryPage: false))
    }

    /// Someone who signs in on the Library page is there to show the code, which the offer's sheet
    /// would cover (https://github.com/tigerduck-app/tigerduck-app/issues/529).
    @Test("the gesture is not offered over the Library page")
    func theOfferWaitsUntilTheLibraryPageIsLeft() {
        #expect(!FlipToLibraryGate.offersGesture(signedInToLibrary: true, enabled: false, asked: false, onLibraryPage: true))
    }

    /// What's New and the update prompt share the root with the offer, and two sheets set there in
    /// one render leave one unshown, so the offer waits for them as for any sheet already up.
    @Test("the offer waits behind a sheet already up and behind What's New or the update prompt")
    func theOfferWaitsForOtherSheets() {
        #expect(!FlipToLibraryGate.offerWaits(sheetPresented: false, notifySheetPending: false))
        #expect(FlipToLibraryGate.offerWaits(sheetPresented: true, notifySheetPending: false))
        #expect(FlipToLibraryGate.offerWaits(sheetPresented: false, notifySheetPending: true))
    }
}
#endif

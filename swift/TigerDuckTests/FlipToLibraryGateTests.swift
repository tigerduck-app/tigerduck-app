#if os(iOS)
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
}
#endif
